"""将旅行规划 API 接入日常 App 的登录与服务端配置。"""

import logging
import os
import threading
from functools import lru_cache
from typing import Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query

from travel_planner_core.agents.trip_planner_agent import get_trip_planner_agent
from travel_planner_core.config import get_settings
from travel_planner_core.models.schemas import (
    RouteInfo,
    RouteRequest,
    RouteResponse,
    TripPlanResponse,
    TripRequest,
    WeatherInfo,
    WeatherResponse,
)
from travel_planner_core.planner.amap import AmapPlannerClient
from travel_planner_core.planner.pois import filter_pois, normalize_pois, rank_pois


logger = logging.getLogger(__name__)
_planner_lock = threading.Lock()


@lru_cache(maxsize=1)
def _amap_client() -> AmapPlannerClient:
    settings = get_settings()
    api_key = settings.amap_api_key or os.getenv("AMAP_MAPS_API_KEY", "")
    return AmapPlannerClient(api_key)


def _amap_data(path: str, params: dict) -> dict:
    try:
        return _amap_client().get(path, params)
    except Exception as error:
        logger.warning("高德请求失败: %s", path, exc_info=error)
        raise HTTPException(502, "地图服务暂时不可用，请稍后重试") from None


def _search_pois(
    keywords: str,
    city: str,
    role: str,
    limit: int = 10,
    citylimit: bool = True,
) -> list[dict]:
    try:
        if not citylimit:
            raw = _amap_client().get(
                "/place/text",
                {
                    "keywords": keywords,
                    "city": city,
                    "citylimit": "false",
                    "extensions": "all",
                    "offset": 20,
                    "page": 1,
                },
            )
            rows = normalize_pois(raw, keywords, role, True, "frontend_search")
            return rank_pois(filter_pois(rows, role), role)[:limit]
        return _amap_client().search_keywords(
            city=city,
            keywords=[keywords],
            source_role=role,
            limit=limit,
            require_location=True,
            source_bucket="frontend_search",
        )
    except Exception as error:
        logger.warning("高德 POI 搜索失败", exc_info=error)
        raise HTTPException(502, "地点搜索暂时不可用，请稍后重试") from None


def create_travel_router(current_user):
    """所有旅行服务都沿用当前 App 的 Bearer 登录校验。"""
    router = APIRouter(
        prefix="/travel",
        tags=["travel"],
        dependencies=[Depends(current_user)],
    )

    @router.post("/plan", response_model=TripPlanResponse)
    def plan_trip(request: TripRequest):
        settings = get_settings()
        if not (settings.amap_api_key or os.getenv("AMAP_MAPS_API_KEY")):
            raise HTTPException(503, "旅行规划服务尚未配置高德地图")
        if not (
            os.getenv("LLM_API_KEY")
            or os.getenv("DEEPSEEK_API_KEY")
            or os.getenv("OPENAI_API_KEY")
            or settings.openai_api_key
        ):
            raise HTTPException(503, "旅行规划服务尚未配置 LLM")
        try:
            # ponytail: 串行使用共享 SimpleAgent，避免并发请求互相覆盖对话历史。
            with _planner_lock:
                agent = get_trip_planner_agent()
                plan = agent.plan_trip(request)
                message = agent.last_generation_message or "旅行计划生成完成"
            return TripPlanResponse(success=True, message=message, data=plan)
        except Exception as error:
            logger.exception("旅行规划生成失败")
            if "AMAP_API_KEY" in str(error) or "LLM" in str(error):
                raise HTTPException(503, "旅行规划服务尚未完成配置") from None
            raise HTTPException(502, "行程生成失败，请稍后重试") from None

    @router.get("/health")
    def travel_health():
        settings = get_settings()
        has_llm = bool(
            os.getenv("LLM_API_KEY")
            or os.getenv("DEEPSEEK_API_KEY")
            or os.getenv("OPENAI_API_KEY")
            or settings.openai_api_key
        )
        return {
            "status": "ready" if settings.amap_api_key and has_llm else "configuration_required",
            "amap_configured": bool(settings.amap_api_key or os.getenv("AMAP_MAPS_API_KEY")),
            "llm_configured": has_llm,
        }

    @router.get("/poi/search")
    def search_poi(
        keywords: str = Query(min_length=1, max_length=120),
        city: str = Query(default="北京", min_length=1, max_length=80),
        source_role: Literal["food", "scenic", "hotel"] = "food",
    ):
        return {
            "success": True,
            "message": "搜索成功",
            "data": _search_pois(keywords, city, source_role),
        }

    @router.get("/poi/detail/{poi_id}")
    def poi_detail(poi_id: str):
        data = _amap_data("/place/detail", {"id": poi_id, "extensions": "all"})
        details = data.get("pois") or []
        return {
            "success": True,
            "message": "获取 POI 详情成功",
            "data": details[0] if details else None,
        }

    @router.get("/poi/photo")
    def poi_photo(name: str = Query(min_length=1, max_length=120)):
        access_key = os.getenv("UNSPLASH_ACCESS_KEY", "").strip()
        photo = None
        if access_key:
            for query in (f"{name} China landmark", name):
                try:
                    response = httpx.get(
                        "https://api.unsplash.com/search/photos",
                        params={"query": query, "per_page": 1},
                        headers={"Authorization": f"Client-ID {access_key}"},
                        timeout=10,
                    )
                    response.raise_for_status()
                    results = response.json().get("results", [])
                    if results:
                        item = results[0]
                        photo = {
                            "photo_url": item.get("urls", {}).get("regular"),
                            "photographer": item.get("user", {}).get("name"),
                            "photographer_url": item.get("user", {}).get("links", {}).get("html"),
                        }
                        break
                except (httpx.HTTPError, ValueError):
                    logger.info("Unsplash 图片查询未命中")
        return {"success": True, "message": "获取图片成功", "data": {"name": name, **(photo or {})}}

    @router.get("/map/poi")
    def map_poi(
        keywords: str = Query(min_length=1, max_length=120),
        city: str = Query(min_length=1, max_length=80),
        citylimit: bool = True,
    ):
        return {
            "success": True,
            "message": "POI 搜索成功",
            "data": _search_pois(keywords, city, "scenic", citylimit=citylimit),
        }

    @router.get("/map/weather", response_model=WeatherResponse)
    def map_weather(city: str = Query(min_length=1, max_length=80)):
        data = _amap_data("/weather/weatherInfo", {"city": city, "extensions": "all"})
        forecasts = data.get("forecasts") or []
        casts = forecasts[0].get("casts", []) if forecasts else []
        return WeatherResponse(success=True, message="天气查询成功", data=[
            WeatherInfo(
                date=item.get("date", ""),
                day_weather=item.get("dayweather", ""),
                night_weather=item.get("nightweather", ""),
                day_temp=item.get("daytemp", 0),
                night_temp=item.get("nighttemp", 0),
                wind_direction=item.get("daywind", ""),
                wind_power=item.get("daypower", ""),
            )
            for item in casts
        ])

    @router.post("/map/route", response_model=RouteResponse)
    def map_route(request: RouteRequest):
        origin = _geocode(request.origin_address, request.origin_city)
        destination = _geocode(request.destination_address, request.destination_city)
        route_paths = {
            "walking": "/direction/walking",
            "driving": "/direction/driving",
            "transit": "/direction/transit/integrated",
        }
        route_type = request.route_type if request.route_type in route_paths else "walking"
        params = {"origin": origin, "destination": destination}
        if route_type == "transit":
            params["city"] = request.origin_city or ""
            params["cityd"] = request.destination_city or ""
        data = _amap_data(route_paths[route_type], params)
        route = data.get("route") or {}
        paths = route.get("paths") or route.get("transits") or []
        if not paths:
            raise HTTPException(404, "没有找到可用路线")
        path = paths[0]
        steps = path.get("steps") or path.get("segments") or []
        instructions = [
            str(step.get("instruction") or step.get("walking", {}).get("steps", [{}])[0].get("instruction") or "")
            for step in steps
        ]
        return RouteResponse(
            success=True,
            message="路线规划成功",
            data=RouteInfo(
                distance=float(path.get("distance") or 0),
                duration=int(float(path.get("duration") or 0)),
                route_type=route_type,
                description="；".join(text for text in instructions if text) or "路线已规划",
            ),
        )

    @router.get("/map/health")
    def map_health():
        configured = bool(get_settings().amap_api_key or os.getenv("AMAP_MAPS_API_KEY"))
        if not configured:
            raise HTTPException(503, "高德地图服务尚未配置")
        return {"status": "healthy", "service": "map-service"}

    return router


def _geocode(address: str, city: str | None) -> str:
    data = _amap_data("/geocode/geo", {"address": address, "city": city})
    geocodes = data.get("geocodes") or []
    if not geocodes or not geocodes[0].get("location"):
        raise HTTPException(404, "无法识别起点或终点地址")
    return str(geocodes[0]["location"])
