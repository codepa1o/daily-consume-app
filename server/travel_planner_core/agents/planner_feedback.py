"""Planner 在线失败样本和偏好候选落盘逻辑。"""

import json
import os
from datetime import datetime, timezone
from typing import Any, Dict, List

from ..models.schemas import TripPlan, TripRequest
from ..services.mcp_env import PROJECT_ROOT


ONLINE_FEEDBACK_DIR = PROJECT_ROOT / "training" / "data" / "online_feedback"
PLANNER_FAILURE_LOG = ONLINE_FEEDBACK_DIR / "planner_failures.jsonl"
PLANNER_DPO_CANDIDATE_LOG = ONLINE_FEEDBACK_DIR / "planner_dpo_candidates.jsonl"


class PlannerGenerationError(ValueError):
    """Raised when a planner cannot produce valid TripPlan JSON."""

    def __init__(self, message: str, failures: List[Dict[str, Any]]):
        super().__init__(message)
        self.failures = failures


def is_non_retryable_llm_error(error: Exception) -> bool:
    """判断同一 prompt 继续重试也很难恢复的 LLM 接口错误。"""
    text = str(error).lower()
    return (
        "content exists risk" in text
        or ("invalid_request_error" in text and "400" in text)
    )


def build_failure_row(
    label: str,
    attempt: int,
    max_attempts: int,
    request: TripRequest,
    planner_query: str,
    response: str,
    error: Exception,
    preference_reason: str = "planner_schema_invalid",
) -> Dict[str, Any]:
    """Build an online feedback row for invalid planner output."""
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "label": label,
        "attempt": attempt,
        "max_attempts": max_attempts,
        "request": request.model_dump(),
        "prompt": planner_query,
        "rejected": response,
        "error_type": type(error).__name__,
        "error": str(error),
        "preference_reason": preference_reason,
    }


def log_preference_candidates(
    planner_query: str,
    request: TripRequest,
    chosen_plan: TripPlan,
    failures: List[Dict[str, Any]],
    chosen_label: str = "默认 Planner",
) -> None:
    """Log DPO candidate rows using invalid planner outputs as rejected."""
    chosen_value = json.dumps(chosen_plan.model_dump(), ensure_ascii=False)
    for failure in failures:
        row = {
            "conversations": [{"from": "human", "value": planner_query}],
            "chosen": {"from": "gpt", "value": chosen_value},
            "rejected": {"from": "gpt", "value": failure["rejected"]},
            "preference_reason": failure.get("preference_reason", "planner_schema_invalid"),
            "metadata": {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "request": request.model_dump(),
                "rejected_label": failure.get("label"),
                "rejected_attempt": failure.get("attempt"),
                "chosen_label": chosen_label,
                "error": failure.get("error"),
            },
        }
        append_jsonl(PLANNER_DPO_CANDIDATE_LOG, row)


def append_jsonl(path, row: Dict[str, Any]) -> None:
    """Append one JSONL row, creating the directory on demand."""
    # 规划输入可能包含个人行程偏好，默认不持久化到训练样本文件。
    if os.getenv("PLANNER_FEEDBACK_ENABLED", "0") != "1":
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(row, ensure_ascii=False) + "\n")
