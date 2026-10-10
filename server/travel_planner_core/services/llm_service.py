"""LLM服务模块"""

import os
from contextlib import contextmanager
from typing import Any, Iterator

from hello_agents import HelloAgentsLLM
from hello_agents.core.exceptions import HelloAgentsException
from ..config import get_settings

# 全局LLM实例
_llm_instance = None
_planner_llm_instance = None


class RobustHelloAgentsLLM(HelloAgentsLLM):
    """Compatibility wrapper for OpenAI-compatible providers.

    hello-agents 0.2.9 assumes chat.completions.create always returns an
    OpenAI SDK object with response.choices[0].message.content. Some gateways
    return a plain string or a dict-like response instead. That makes the
    planner fail before it can parse a valid TripPlan JSON.
    """

    def invoke(self, messages: list[dict[str, str]], **kwargs) -> str:
        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": kwargs.get("temperature", self.temperature),
            "max_tokens": kwargs.get("max_tokens", self.max_tokens),
        }
        payload.update({k: v for k, v in kwargs.items() if k not in {"temperature", "max_tokens"}})
        payload = {key: value for key, value in payload.items() if value is not None}

        try:
            response = self._client.chat.completions.create(**payload)
            return self._extract_text(response)
        except TypeError as error:
            if "max_tokens" not in str(error):
                raise
            retry_payload = dict(payload)
            max_tokens = retry_payload.pop("max_tokens", None)
            if max_tokens is not None:
                retry_payload["max_completion_tokens"] = max_tokens
            response = self._client.chat.completions.create(**retry_payload)
            return self._extract_text(response)
        except Exception as error:
            raise HelloAgentsException(f"LLM调用失败: {error}") from error

    def _extract_text(self, response: Any) -> str:
        if isinstance(response, str):
            if self._looks_like_html(response):
                raise HelloAgentsException(
                    "LLM服务返回了HTML页面，请检查LLM_BASE_URL是否指向OpenAI兼容API地址，"
                    "通常应以/v1结尾。"
                )
            return response

        if isinstance(response, dict):
            if isinstance(response.get("output_text"), str):
                return response["output_text"]

            choices = response.get("choices") or []
            if choices:
                message = choices[0].get("message") if isinstance(choices[0], dict) else None
                if isinstance(message, dict):
                    return self._content_to_text(message.get("content"))
                if isinstance(choices[0].get("text"), str):
                    return choices[0]["text"]

            return self._content_to_text(response.get("output"))

        output_text = getattr(response, "output_text", None)
        if isinstance(output_text, str):
            return output_text

        choices = getattr(response, "choices", None)
        if choices:
            message = getattr(choices[0], "message", None)
            if message is not None:
                return self._content_to_text(getattr(message, "content", ""))
            text = getattr(choices[0], "text", None)
            if isinstance(text, str):
                return text

        output = getattr(response, "output", None)
        if output is not None:
            return self._content_to_text(output)

        raise ValueError(f"无法从LLM响应中提取文本: {type(response).__name__}")

    def _looks_like_html(self, text: str) -> bool:
        preview = text.lstrip()[:128].lower()
        return preview.startswith("<!doctype html") or preview.startswith("<html")

    def _content_to_text(self, content: Any) -> str:
        if content is None:
            return ""
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, str):
                    parts.append(item)
                elif isinstance(item, dict):
                    text = item.get("text") or item.get("content")
                    if isinstance(text, str):
                        parts.append(text)
                else:
                    text = getattr(item, "text", None) or getattr(item, "content", None)
                    if isinstance(text, str):
                        parts.append(text)
            return "".join(parts)
        return str(content)


@contextmanager
def _temporary_env(overrides: dict[str, str]) -> Iterator[None]:
    """临时覆盖环境变量，用于创建独立 LLM 实例。"""
    previous = {key: os.environ.get(key) for key in overrides}
    try:
        for key, value in overrides.items():
            if value:
                os.environ[key] = value
        yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def get_llm() -> HelloAgentsLLM:
    """
    获取LLM实例(单例模式)

    Returns:
        HelloAgentsLLM实例
    """
    global _llm_instance

    if _llm_instance is None:
        settings = get_settings()

        # 旅行规划复用日常 App 已有的 DeepSeek 配置，也兼容 HelloAgents 的环境变量名。
        defaults = {
            key: value
            for key, value in {
                "LLM_API_KEY": os.getenv("DEEPSEEK_API_KEY") or settings.openai_api_key,
                "LLM_BASE_URL": os.getenv("DEEPSEEK_BASE_URL") or settings.openai_base_url,
                "LLM_MODEL_ID": os.getenv("DEEPSEEK_MODEL") or settings.openai_model,
            }.items()
            if not os.getenv(key)
        }
        with _temporary_env(defaults):
            _llm_instance = RobustHelloAgentsLLM()

        print(f"✅ LLM服务初始化成功")
        print(f"   提供商: {_llm_instance.provider}")
        print(f"   模型: {_llm_instance.model}")

    return _llm_instance


def get_planner_llm() -> HelloAgentsLLM:
    """
    获取最终行程规划 LLM。

    默认返回通用 LLM；当 USE_PERSONALIZED_PLANNER=true 且配置完整时，
    仅 planner agent 使用个性化微调模型。
    """
    global _planner_llm_instance

    settings = get_settings()
    if not settings.use_personalized_planner:
        return get_llm()

    if _planner_llm_instance is None:
        model = os.getenv("PERSONALIZED_LLM_MODEL_ID") or settings.personalized_llm_model
        base_url = settings.personalized_llm_base_url
        api_key = settings.personalized_llm_api_key or "EMPTY"
        provider = settings.personalized_llm_provider or "openai"

        if not model or not base_url:
            print("⚠️  个性化 Planner 配置不完整，将使用默认 LLM")
            return get_llm()

        overrides = {
            "LLM_API_KEY": api_key,
            "OPENAI_API_KEY": api_key,
            "LLM_BASE_URL": base_url,
            "OPENAI_BASE_URL": base_url,
            "LLM_MODEL_ID": model,
            "OPENAI_MODEL": model,
            "LLM_PROVIDER": provider,
        }
        with _temporary_env(overrides):
            _planner_llm_instance = RobustHelloAgentsLLM()

        print("✅ 个性化 Planner LLM 初始化成功")
        print(f"   提供商: {_planner_llm_instance.provider}")
        print(f"   模型: {_planner_llm_instance.model}")
        print(f"   Base URL: {base_url}")

    return _planner_llm_instance


def reset_llm():
    """重置LLM实例(用于测试或重新配置)"""
    global _llm_instance, _planner_llm_instance
    _llm_instance = None
    _planner_llm_instance = None
