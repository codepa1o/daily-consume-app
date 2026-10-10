"""Planner 候选重排（rerank）逻辑。"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass
from typing import Any, Dict, List, Tuple

from ..models.schemas import TripPlan, TripRequest
from .output import (
    candidate_names,
    is_lodging_breakfast_meal,
    name_in_candidates,
    normalize_poi_name,
)


MEAL_PER_PERSON_FLOOR_BY_BUDGET_LEVEL = {
    "limited": 25,
    "economy": 25,
    "standard": 35,
    "medium": 35,
    "comfortable": 50,
    "upper": 50,
    "premium": 70,
    "luxury": 100,
}


@dataclass
class RerankCandidate:
    """单个候选计划及其重排得分。"""

    attempt: int
    trip_plan: TripPlan
    score: float
    metrics: Dict[str, Any]


def rerank_trip_plan_candidates(
    candidates: List[Tuple[int, TripPlan]],
    request: TripRequest,
    planner_context: Dict[str, Any] | None,
) -> List[RerankCandidate]:
    """为候选 TripPlan 打分并按分数降序返回。"""
    scored: List[RerankCandidate] = []
    for attempt, trip_plan in candidates:
        metrics = score_trip_plan_candidate(trip_plan, request, planner_context or {})
        score = score_rerank_metrics(metrics)
        scored.append(
            RerankCandidate(
                attempt=attempt,
                trip_plan=trip_plan,
                score=score,
                metrics=metrics,
            )
        )

    scored.sort(key=lambda row: (-row.score, row.attempt))
    return scored


def score_trip_plan_candidate(
    trip_plan: TripPlan,
    request: TripRequest,
    planner_context: Dict[str, Any],
) -> Dict[str, Any]:
    """计算一个 TripPlan 候选的 rerank 指标。"""
    snapshot = (planner_context.get("tool_snapshot") or {}) if isinstance(planner_context, dict) else {}
    attraction_candidates = candidate_names(
        (snapshot.get("classic_pois") or [])
        + (snapshot.get("preference_pois") or [])
        + (snapshot.get("scenic_pois") or [])
        + (snapshot.get("experience_pois") or [])
    )
    hotel_candidates = candidate_names(snapshot.get("hotel_pois") or [])
    food_candidates = candidate_names(snapshot.get("food_pois") or [])

    attraction_total = 0
    attraction_hit = 0
    hotel_total = 0
    hotel_hit = 0
    meal_total = 0
    meal_hit = 0

    meal_diversity_counts: Counter[str] = Counter()
    attraction_diversity_counts: Counter[str] = Counter()
    same_day_lunch_dinner_ok = True

    food_candidate_keys = {
        key
        for name in food_candidates
        if (key := _meal_diversity_key(name))
    }
    food_candidate_count = len(food_candidate_keys)

    for day in trip_plan.days:
        day_lunch_key = ""
        day_dinner_key = ""

        for attraction in day.attractions:
            attraction_total += 1
            if name_in_candidates(attraction.name, attraction_candidates):
                attraction_hit += 1
            diversity_key = _attraction_diversity_key(attraction.name)
            if diversity_key:
                attraction_diversity_counts[diversity_key] += 1

        if day.hotel is not None:
            hotel_total += 1
            if name_in_candidates(day.hotel.name, hotel_candidates):
                hotel_hit += 1

        for meal in day.meals:
            meal_total += 1
            meal_type = str(meal.type or "").strip().lower()
            meal_name = str(meal.name or "")
            lodging_breakfast = is_lodging_breakfast_meal(meal_name, meal_type)
            if lodging_breakfast or name_in_candidates(meal_name, food_candidates):
                meal_hit += 1

            diversity_key = _meal_diversity_key(meal_name)
            if diversity_key and not lodging_breakfast:
                meal_diversity_counts[diversity_key] += 1
                if meal_type == "lunch":
                    day_lunch_key = diversity_key
                elif meal_type == "dinner":
                    day_dinner_key = diversity_key

        if food_candidate_count >= 2 and day_lunch_key and day_dinner_key and day_lunch_key == day_dinner_key:
            same_day_lunch_dinner_ok = False

    meal_repeat_limit_ok = True
    if food_candidate_count >= 3:
        max_allowed_repeat = max(2, (len(trip_plan.days) * 3 + 4) // 5)
        for count in meal_diversity_counts.values():
            if count > max_allowed_repeat:
                meal_repeat_limit_ok = False
                break

    attraction_diversity_ok = True
    for count in attraction_diversity_counts.values():
        if count > 1:
            attraction_diversity_ok = False
            break

    recomputed_budget = recompute_budget_from_selected_items(trip_plan, request)
    budget_fit = budget_fit_details(
        total=recomputed_budget["total"],
        request=request,
        planner_context=planner_context,
    )
    budget_relationship = budget_relationship_details(
        trip_plan=trip_plan,
        request=request,
        recomputed_budget=recomputed_budget,
    )
    arithmetic_consistent = budget_arithmetic_consistent(trip_plan)

    return {
        "attraction_grounding_rate": _metric_rate(attraction_hit, attraction_total),
        "attraction_grounding_ok": attraction_hit == attraction_total and attraction_total > 0,
        "hotel_grounding_rate": _metric_rate(hotel_hit, hotel_total),
        "hotel_grounding_ok": hotel_hit == hotel_total and hotel_total > 0,
        "meal_grounding_rate": _metric_rate(meal_hit, meal_total),
        "meal_grounding_ok": meal_hit == meal_total and meal_total > 0,
        "attraction_diversity_ok": attraction_diversity_ok,
        "meal_diversity_ok": same_day_lunch_dinner_ok and meal_repeat_limit_ok,
        "meal_lunch_dinner_same_day_ok": same_day_lunch_dinner_ok,
        "meal_repeat_limit_ok": meal_repeat_limit_ok,
        "budget_hard_constraint_ok": budget_fit["hard_constraint_ok"],
        "recomputed_budget_fit_ok": budget_fit["fit_ok"],
        "budget_fit_distance_ratio": budget_fit["distance_ratio"],
        "budget_fit_closeness": budget_fit["closeness"],
        "budget_relationship_ok": budget_relationship["budget_relationship_ok"],
        "hotel_budget_relation_ok": budget_relationship["hotel_budget_relation_ok"],
        "attraction_budget_party_relation_ok": budget_relationship["attraction_budget_party_relation_ok"],
        "meal_cost_scale_ok": budget_relationship["meal_cost_scale_ok"],
        "budget_arithmetic_consistent": arithmetic_consistent,
        "recomputed_budget_total": recomputed_budget["total"],
        "recomputed_budget": recomputed_budget,
        "budget_target_min_total": budget_fit["target_min_total"],
        "budget_target_max_total": budget_fit["target_max_total"],
    }


def score_rerank_metrics(metrics: Dict[str, Any]) -> float:
    """把 rerank 指标映射成一个可比较的总分。"""
    score = 0.0

    score += 16.0 if metrics.get("budget_hard_constraint_ok") else -40.0

    if metrics.get("recomputed_budget_fit_ok"):
        score += 26.0
    else:
        distance_ratio = float(metrics.get("budget_fit_distance_ratio") or 0.0)
        score += max(-24.0, 12.0 - distance_ratio * 60.0)

    score += 12.0 if metrics.get("budget_relationship_ok") else -8.0
    score += 8.0 if metrics.get("meal_cost_scale_ok") else -8.0
    score += 10.0 if metrics.get("meal_diversity_ok") else -10.0
    score += 6.0 if metrics.get("attraction_diversity_ok") else -6.0

    score += float(metrics.get("meal_grounding_rate") or 0.0) * 18.0
    score += float(metrics.get("attraction_grounding_rate") or 0.0) * 12.0
    score += float(metrics.get("hotel_grounding_rate") or 0.0) * 8.0

    score += 4.0 if metrics.get("budget_arithmetic_consistent") else 0.0
    score += max(0.0, float(metrics.get("budget_fit_closeness") or 0.0)) * 6.0

    return round(score, 4)


def recompute_budget_from_selected_items(trip_plan: TripPlan, request: TripRequest) -> Dict[str, int]:
    """按已选 POI 的价格字段重算预算。"""
    party_total = max(1, _safe_int(request.party.total))
    room_count = _hotel_room_count(request)

    total_hotels = 0
    total_attractions = 0
    total_meals = 0
    for day in trip_plan.days:
        if day.hotel is not None:
            total_hotels += max(0, _safe_int(day.hotel.estimated_cost)) * room_count

        for attraction in day.attractions:
            total_attractions += max(0, _safe_int(attraction.ticket_price)) * party_total

        for meal in day.meals:
            total_meals += max(0, _safe_int(meal.estimated_cost)) * party_total

    reported_transport = _safe_int((trip_plan.budget.total_transportation if trip_plan.budget else 0))
    total_transportation = max(0, reported_transport)
    total = total_attractions + total_hotels + total_meals + total_transportation

    return {
        "total_attractions": total_attractions,
        "total_hotels": total_hotels,
        "total_meals": total_meals,
        "total_transportation": total_transportation,
        "total": total,
    }


def budget_fit_details(total: int, request: TripRequest, planner_context: Dict[str, Any]) -> Dict[str, Any]:
    """评估重算预算是否贴合预算策略。"""
    amount = _safe_int(request.budget_constraint.amount)
    strictness = str(request.budget_constraint.strictness or "none").strip().lower()
    policy = ((planner_context.get("planner_constraints") or {}).get("budget_fit_policy") or {})
    policy_enabled = bool(policy.get("enabled"))
    target_min = _safe_int(policy.get("target_min_total"))
    target_max = _safe_int(policy.get("target_max_total"))

    hard_constraint_ok = True
    if strictness == "hard" and amount > 0:
        hard_constraint_ok = total <= amount

    fit_ok = True
    distance_ratio = 0.0
    closeness = 0.0
    if policy_enabled and target_max > 0:
        fit_ok = target_min <= total <= target_max
        if fit_ok:
            center = (target_min + target_max) / 2.0
            radius = max((target_max - target_min) / 2.0, 1.0)
            closeness = max(0.0, 1.0 - abs(total - center) / radius)
        else:
            if total < target_min:
                gap = target_min - total
            else:
                gap = total - target_max
            span = max(target_max - target_min, int(max(target_min, target_max) * 0.25), 200)
            distance_ratio = round(gap / max(span, 1), 4)
    elif strictness == "hard" and amount > 0:
        fit_ok = hard_constraint_ok
        if not hard_constraint_ok:
            distance_ratio = round((total - amount) / max(amount, 1), 4)
    else:
        fit_ok = total > 0

    return {
        "fit_ok": fit_ok,
        "hard_constraint_ok": hard_constraint_ok,
        "distance_ratio": distance_ratio,
        "closeness": round(closeness, 4),
        "policy_enabled": policy_enabled,
        "target_min_total": target_min,
        "target_max_total": target_max,
    }


def budget_relationship_details(
    trip_plan: TripPlan,
    request: TripRequest,
    recomputed_budget: Dict[str, int],
) -> Dict[str, Any]:
    """检查预算是否体现人数/天数关系。"""
    reported_total_hotels = _safe_int(trip_plan.budget.total_hotels if trip_plan.budget else 0)
    reported_total_attractions = _safe_int(trip_plan.budget.total_attractions if trip_plan.budget else 0)
    expected_total_hotels = _safe_int(recomputed_budget.get("total_hotels"))
    expected_total_attractions = _safe_int(recomputed_budget.get("total_attractions"))

    hotel_budget_relation_ok = _ratio_close(reported_total_hotels, expected_total_hotels, low=0.8, high=1.25)
    attraction_budget_party_relation_ok = _ratio_close(
        reported_total_attractions,
        expected_total_attractions,
        low=0.8,
        high=1.25,
    )

    meal_cost_scale_ok = _meal_cost_scale_ok(trip_plan, request)
    budget_relationship_ok = hotel_budget_relation_ok and attraction_budget_party_relation_ok and meal_cost_scale_ok

    return {
        "hotel_budget_relation_ok": hotel_budget_relation_ok,
        "attraction_budget_party_relation_ok": attraction_budget_party_relation_ok,
        "meal_cost_scale_ok": meal_cost_scale_ok,
        "budget_relationship_ok": budget_relationship_ok,
        "expected_total_hotels": expected_total_hotels,
        "reported_total_hotels": reported_total_hotels,
        "expected_total_attractions": expected_total_attractions,
        "reported_total_attractions": reported_total_attractions,
    }


def budget_arithmetic_consistent(trip_plan: TripPlan) -> bool:
    """预算分项加总是否与 total 一致。"""
    budget = trip_plan.budget
    if budget is None:
        return False

    part_sum = (
        _safe_int(budget.total_attractions)
        + _safe_int(budget.total_hotels)
        + _safe_int(budget.total_meals)
        + _safe_int(budget.total_transportation)
    )
    total = _safe_int(budget.total)
    return total > 0 and part_sum == total


def _meal_cost_scale_ok(trip_plan: TripPlan, request: TripRequest) -> bool:
    budget_level = str(request.budget_constraint.budget_level or "standard").strip().lower()
    floor = MEAL_PER_PERSON_FLOOR_BY_BUDGET_LEVEL.get(budget_level, 35)

    for day in trip_plan.days:
        for meal in day.meals:
            meal_type = str(meal.type or "").strip().lower()
            if meal_type not in {"lunch", "dinner"}:
                continue
            if _safe_int(meal.estimated_cost) < floor:
                return False
    return True


def _meal_diversity_key(name: str) -> str:
    normalized = normalize_poi_name(name)
    if not normalized:
        return ""
    for marker in ("(", "（"):
        if marker in normalized:
            normalized = normalized.split(marker, 1)[0]
    return normalized


def _attraction_diversity_key(name: str) -> str:
    normalized = normalize_poi_name(name)
    if not normalized:
        return ""
    for marker in ("(", "（"):
        if marker in normalized:
            normalized = normalized.split(marker, 1)[0]
    return normalized


def _hotel_room_count(request: TripRequest) -> int:
    total = max(1, _safe_int(request.party.total))
    return max(1, math.ceil(total / 2))


def _ratio_close(reported: int, expected: int, low: float, high: float) -> bool:
    if expected <= 0:
        return reported == 0
    return expected * low <= reported <= expected * high


def _metric_rate(hit: int, total: int) -> float:
    if total <= 0:
        return 0.0
    return round(hit / total, 4)


def _safe_int(value: Any) -> int:
    try:
        return int(value or 0)
    except Exception:  # noqa: BLE001
        return 0
