"""配置管理模块"""

import os
import sys
from pathlib import Path
from typing import List
from pydantic_settings import BaseSettings
from dotenv import load_dotenv


def _configure_stdio_encoding() -> None:
    """Keep Windows GBK consoles from crashing on emoji log output."""
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def _drop_invalid_debug_env() -> None:
    """Ignore non-boolean global DEBUG values such as DEBUG=release."""
    value = os.getenv("DEBUG")
    if value is None:
        return

    normalized = value.strip().lower()
    valid_bool_values = {"1", "0", "true", "false", "yes", "no", "on", "off"}
    if normalized not in valid_bool_values:
        os.environ.pop("DEBUG", None)


_configure_stdio_encoding()

# 加载环境变量
# 首先尝试加载当前目录的.env
load_dotenv()
_drop_invalid_debug_env()

# 然后尝试加载HelloAgents的.env(如果存在)
helloagents_env = Path(__file__).parent.parent.parent.parent / "HelloAgents" / ".env"
if helloagents_env.exists():
    load_dotenv(helloagents_env, override=False)  # 不覆盖已有的环境变量


class Settings(BaseSettings):
    """应用配置"""

    # 应用基本配置
    app_name: str = "HelloAgents智能旅行助手"
    app_version: str = "1.0.0"
    debug: bool = False

    # 服务器配置
    host: str = "0.0.0.0"
    port: int = 7000

    # CORS配置 - 使用字符串,在代码中分割
    cors_origins: str = "http://localhost:5173,http://localhost:3000,http://127.0.0.1:5173,http://127.0.0.1:3000"

    # 高德地图API配置
    amap_api_key: str = ""

    # Unsplash API配置
    unsplash_access_key: str = ""
    unsplash_secret_key: str = ""

    # LLM配置 (从环境变量读取,由HelloAgents管理)
    openai_api_key: str = ""
    openai_base_url: str = "https://api.openai.com/v1"
    openai_model: str = "gpt-4"

    # 个性化行程规划模型配置
    # 开启后仅最终 TripPlan 生成使用该模型，工具搜索/天气/酒店 Agent 仍使用默认 LLM。
    use_personalized_planner: bool = False
    personalized_llm_api_key: str = ""
    personalized_llm_base_url: str = ""
    personalized_llm_model: str = ""
    personalized_llm_provider: str = "openai"

    # 日志配置
    log_level: str = "INFO"

    class Config:
        env_file = ".env"
        case_sensitive = False
        extra = "ignore"  # 忽略额外的环境变量

    def get_cors_origins_list(self) -> List[str]:
        """获取CORS origins列表"""
        return [origin.strip() for origin in self.cors_origins.split(',')]


# 创建全局配置实例
settings = Settings()


def get_settings() -> Settings:
    """获取配置实例"""
    return settings


# 验证必要的配置
def validate_config():
    """验证配置是否完整"""
    errors = []
    warnings = []

    if not settings.amap_api_key:
        errors.append("AMAP_API_KEY未配置")

    # HelloAgentsLLM会自动从LLM_API_KEY读取,不强制要求OPENAI_API_KEY
    llm_api_key = os.getenv("LLM_API_KEY") or os.getenv("OPENAI_API_KEY")
    if not llm_api_key:
        warnings.append("LLM_API_KEY或OPENAI_API_KEY未配置,LLM功能可能无法使用")

    if errors:
        error_msg = "配置错误:\n" + "\n".join(f"  - {e}" for e in errors)
        raise ValueError(error_msg)

    if warnings:
        print("\n⚠️  配置警告:")
        for w in warnings:
            print(f"  - {w}")

    return True


# 打印配置信息(用于调试)
def print_config():
    """打印当前配置(隐藏敏感信息)"""
    print(f"应用名称: {settings.app_name}")
    print(f"版本: {settings.app_version}")
    print(f"服务器: {settings.host}:{settings.port}")
    print(f"高德地图API Key: {'已配置' if settings.amap_api_key else '未配置'}")

    # 检查LLM配置
    llm_api_key = os.getenv("LLM_API_KEY") or os.getenv("OPENAI_API_KEY")
    llm_base_url = os.getenv("LLM_BASE_URL") or settings.openai_base_url
    llm_model = os.getenv("LLM_MODEL_ID") or settings.openai_model
    personalized_model = os.getenv("PERSONALIZED_LLM_MODEL_ID") or settings.personalized_llm_model

    print(f"LLM API Key: {'已配置' if llm_api_key else '未配置'}")
    print(f"LLM Base URL: {llm_base_url}")
    print(f"LLM Model: {llm_model}")
    print(f"Personalized Planner: {'启用' if settings.use_personalized_planner else '关闭'}")
    if settings.use_personalized_planner:
        print(f"Personalized Planner Base URL: {settings.personalized_llm_base_url or '未配置'}")
        print(f"Personalized Planner Model: {personalized_model or '未配置'}")
    print(f"日志级别: {settings.log_level}")
