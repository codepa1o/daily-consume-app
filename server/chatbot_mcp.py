"""聊天机器人使用的 MCP stdio 工具客户端。"""

import asyncio
import json
import logging
import os
import re
from dataclasses import dataclass
from typing import Any


_logger = logging.getLogger(__name__)
_REQUEST_TIMEOUT_SECONDS = 30
_TOOL_RESULT_MAX_CHARS = 12000
_LEGACY_PROTOCOL_VERSIONS = {
    "2024-11-05",
    "2025-03-26",
    "2025-06-18",
    "2025-11-25",
}
_MODERN_PROTOCOL_VERSION = "2026-07-28"


@dataclass(frozen=True)
class MCPTool:
    """已连接 MCP 服务器提供的工具。"""

    name: str
    description: str
    input_schema: dict[str, Any]
    server: "MCPStdioServer"
    original_name: str

    def openai_definition(self) -> dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description[:1000],
                "parameters": self.input_schema,
            },
        }


class MCPStdioServer:
    """通过 MCP 标准输入输出协议连接一个本地工具服务器。"""

    def __init__(
        self,
        name: str,
        command: str,
        args: list[str],
        env: dict[str, str],
        protocol_version: str,
    ):
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.protocol_version = protocol_version
        self.process: asyncio.subprocess.Process | None = None
        self._request_id = 0
        self._stderr_task: asyncio.Task | None = None

    async def connect(self) -> list[MCPTool]:
        inherited = {
            "PATH",
            "HOME",
            "USERPROFILE",
            "APPDATA",
            "TEMP",
            "TMP",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "SYSTEMROOT",
            "WINDIR",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "http_proxy",
            "https_proxy",
            "all_proxy",
            "no_proxy",
        }
        process_env = {key: value for key, value in os.environ.items() if key in inherited}
        process_env.update(self.env)
        self.process = await asyncio.create_subprocess_exec(
            self.command,
            *self.args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=process_env,
        )
        self._stderr_task = asyncio.create_task(self._discard_stderr())
        if self.protocol_version != _MODERN_PROTOCOL_VERSION:
            await self._request(
                "initialize",
                {
                    "protocolVersion": self.protocol_version,
                    "capabilities": {},
                    "clientInfo": {"name": "daily-consume-chatbot", "version": "1"},
                },
            )
            await self._notify("notifications/initialized", {})
        result = await self._request("tools/list", {})
        tools = result.get("tools", []) if isinstance(result, dict) else []
        output: list[MCPTool] = []
        used_names: set[str] = set()
        for item in tools:
            if not isinstance(item, dict):
                continue
            original_name = str(item.get("name") or "").strip()
            if not original_name:
                continue
            safe_server = re.sub(r"[^A-Za-z0-9_]", "_", self.name)
            safe_tool = re.sub(r"[^A-Za-z0-9_]", "_", original_name)
            name = f"mcp_{safe_server}_{safe_tool}"[:64]
            if name in used_names:
                name = f"{name[:52]}_{len(used_names)}"
            used_names.add(name)
            schema = item.get("inputSchema")
            if not isinstance(schema, dict) or schema.get("type") != "object":
                schema = {"type": "object", "properties": {}}
            output.append(
                MCPTool(
                    name=name,
                    description=str(item.get("description") or ""),
                    input_schema=schema,
                    server=self,
                    original_name=original_name,
                )
            )
        return output

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> str:
        result = await self._request(
            "tools/call",
            {"name": name, "arguments": arguments},
        )
        if not isinstance(result, dict):
            return str(result)[:_TOOL_RESULT_MAX_CHARS]
        content = result.get("content", [])
        texts = [
            str(item.get("text") or "")
            for item in content
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        structured = result.get("structuredContent")
        if structured is not None:
            texts.append(json.dumps(structured, ensure_ascii=False, default=str))
        value = "\n".join(texts).strip()
        if result.get("isError"):
            value = f"MCP 工具返回错误：{value or '未知错误'}"
        return value[:_TOOL_RESULT_MAX_CHARS] or "工具没有返回文本内容。"

    async def _request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        process = self.process
        if process is None or process.stdin is None or process.stdout is None:
            raise RuntimeError(f"MCP 服务器 {self.name} 尚未启动")
        self._request_id += 1
        request_id = self._request_id
        params = dict(params)
        if self.protocol_version == _MODERN_PROTOCOL_VERSION:
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": self.protocol_version,
                "io.modelcontextprotocol/clientCapabilities": {},
                "io.modelcontextprotocol/clientInfo": {
                    "name": "daily-consume-chatbot",
                    "version": "1",
                },
            }
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
        process.stdin.write(
            (json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8")
        )
        await process.stdin.drain()
        while True:
            line = await asyncio.wait_for(
                process.stdout.readline(),
                timeout=_REQUEST_TIMEOUT_SECONDS,
            )
            if not line:
                raise RuntimeError(f"MCP 服务器 {self.name} 已关闭")
            response = json.loads(line)
            if not isinstance(response, dict) or response.get("id") != request_id:
                continue
            if response.get("error"):
                error = response["error"]
                raise RuntimeError(
                    str(error.get("message") if isinstance(error, dict) else error)
                )
            result = response.get("result")
            return result if isinstance(result, dict) else {"value": result}

    async def _notify(self, method: str, params: dict[str, Any]) -> None:
        process = self.process
        if process is None or process.stdin is None:
            return
        process.stdin.write(
            (
                json.dumps(
                    {"jsonrpc": "2.0", "method": method, "params": params},
                    ensure_ascii=False,
                )
                + "\n"
            ).encode("utf-8")
        )
        await process.stdin.drain()

    async def _discard_stderr(self) -> None:
        process = self.process
        if process is None or process.stderr is None:
            return
        while await process.stderr.readline():
            pass

    async def close(self) -> None:
        process = self.process
        self.process = None
        if process is not None and process.returncode is None:
            if process.stdin is not None:
                process.stdin.close()
            try:
                await asyncio.wait_for(process.wait(), timeout=2)
            except asyncio.TimeoutError:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=2)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()
        if self._stderr_task is not None:
            self._stderr_task.cancel()
            self._stderr_task = None


class MCPToolbox:
    """为单次聊天加载并关闭服务端配置的 MCP 工具。"""

    def __init__(self):
        self.tools: list[MCPTool] = []
        self.warnings: list[str] = []
        self._servers: list[MCPStdioServer] = []

    async def __aenter__(self) -> "MCPToolbox":
        raw = os.getenv("CHATBOT_MCP_SERVERS", "").strip()
        if not raw:
            return self
        try:
            configs = json.loads(raw)
        except json.JSONDecodeError:
            _logger.error("CHATBOT_MCP_SERVERS 不是有效 JSON")
            self.warnings.append("MCP 配置格式无效")
            return self
        if not isinstance(configs, list):
            self.warnings.append("MCP 配置必须是服务器数组")
            return self

        used_server_names: set[str] = set()
        for config in configs[:8]:
            if not isinstance(config, dict):
                continue
            name = str(config.get("name") or "").strip()
            command = str(config.get("command") or "").strip()
            args = config.get("args", [])
            env = config.get("env", {})
            protocol_version = str(
                config.get("protocol_version") or "2024-11-05"
            ).strip()
            if (
                not name
                or name in used_server_names
                or not command
                or protocol_version not in (
                    _LEGACY_PROTOCOL_VERSIONS | {_MODERN_PROTOCOL_VERSION}
                )
                or not isinstance(args, list)
                or any(not isinstance(item, str) for item in args)
                or not isinstance(env, dict)
                or any(not isinstance(key, str) or not isinstance(value, str) for key, value in env.items())
            ):
                self.warnings.append("已跳过无效的 MCP 服务器配置")
                continue
            used_server_names.add(name)
            server = MCPStdioServer(
                name,
                command,
                args,
                env,
                protocol_version,
            )
            try:
                self.tools.extend(await server.connect())
                self._servers.append(server)
            except Exception as error:
                _logger.warning("MCP 服务器加载失败：%s", name, exc_info=True)
                self.warnings.append(f"{name} 连接失败：{type(error).__name__}")
                await server.close()
        return self

    async def __aexit__(self, *_: Any) -> None:
        await asyncio.gather(
            *(server.close() for server in self._servers),
            return_exceptions=True,
        )
        self._servers.clear()

    def definitions(self) -> list[dict[str, Any]]:
        return [tool.openai_definition() for tool in self.tools]

    async def call(self, name: str, arguments: dict[str, Any]) -> str:
        tool = next((item for item in self.tools if item.name == name), None)
        if tool is None:
            return "工具不可用。"
        try:
            return await tool.server.call_tool(tool.original_name, arguments)
        except Exception as error:
            _logger.warning("MCP 工具调用失败：%s", name, exc_info=True)
            return f"工具调用失败：{type(error).__name__}"
