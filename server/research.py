"""论文搜索与下载 API。"""
import json
import logging
import shutil
import tempfile
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, HTTPException
from fastapi.background import BackgroundTask
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

logger = logging.getLogger(__name__)

PaperSource = Literal[
    "arxiv",
    "openreview",
    "acl_anthology",
    "biorxiv",
    "medrxiv",
    "pmlr",
    "pmc_oa",
]

SOURCE_CLASSES = {
    "arxiv": "ArxivPaperClient",
    "openreview": "OpenReviewPaperClient",
    "acl_anthology": "ACLAnthologyPaperClient",
    "biorxiv": "BioRxivPaperClient",
    "medrxiv": "MedRxivPaperClient",
    "pmlr": "PMLRPaperClient",
    "pmc_oa": "PMCOAPaperClient",
}

SOURCE_HOSTS = {
    "arxiv": {"arxiv.org", "export.arxiv.org"},
    "openreview": {"openreview.net"},
    "acl_anthology": {"aclanthology.org"},
    "biorxiv": {"biorxiv.org"},
    "medrxiv": {"medrxiv.org"},
    "pmlr": {"proceedings.mlr.press"},
    "pmc_oa": {
        "pmc.ncbi.nlm.nih.gov",
        "www.ncbi.nlm.nih.gov",
        "ftp.ncbi.nlm.nih.gov",
        "europepmc.org",
    },
}


class PaperSearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    query: str = Field(min_length=1, max_length=200)
    sources: list[PaperSource] = Field(default_factory=lambda: ["arxiv"], min_length=1, max_length=7)
    limit: int = Field(default=10, ge=1, le=30)
    venue_id: str | None = Field(default=None, max_length=160)

    @field_validator("query")
    @classmethod
    def clean_query(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("请输入论文关键词或标题")
        return value

    @field_validator("venue_id")
    @classmethod
    def clean_venue_id(cls, value: str | None) -> str | None:
        return value.strip() or None if value is not None else None


class PaperDownloadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source: PaperSource
    paper: dict


def create_research_router(current_user):
    router = APIRouter(
        prefix="/research",
        tags=["research"],
        dependencies=[Depends(current_user)],
    )

    @router.post("/papers/search")
    async def search_papers(request: PaperSearchRequest):
        if "openreview" in request.sources and not request.venue_id:
            raise HTTPException(422, "搜索 OpenReview 论文时请填写会议 ID")

        try:
            from paperdl import PaperClient
        except ImportError:
            raise HTTPException(503, "论文搜索服务尚未安装") from None

        search_kwargs = {}
        if request.venue_id and "openreview" in request.sources:
            search_kwargs["openreview"] = {"venue_id": request.venue_id}
        for source in ("biorxiv", "medrxiv"):
            if source in request.sources:
                search_kwargs[source] = {"max_scan_results": 500}
        if "pmlr" in request.sources:
            search_kwargs["pmlr"] = {"max_volumes": 120}

        try:
            async with PaperClient(
                request.sources,
                default_init_kwargs={"verbose": False, "show_progress": False},
                client_search_kwargs=search_kwargs,
            ) as client:
                papers_by_source = await client.search(
                    request.query,
                    total_results=request.limit,
                    return_by_client=True,
                    return_exceptions=True,
                )
                errors = dict(client.last_errors)
        except Exception:
            logger.exception("论文搜索失败")
            raise HTTPException(502, "论文搜索暂时失败，请稍后重试") from None

        results = []
        for source in request.sources:
            papers = papers_by_source.get(source, [])
            if isinstance(papers, BaseException):
                errors.setdefault(source, papers)
                continue
            for paper in papers:
                try:
                    record = json.loads(paper.tojson(ensure_ascii=False, indent=None))
                except (AttributeError, TypeError, ValueError):
                    logger.exception("无法序列化论文记录")
                    continue
                results.append(
                    {
                        "id": f"{source}:{paper.identity_key}",
                        "source": source,
                        "title": paper.title,
                        "authors": paper.authors,
                        "year": paper.year,
                        "venue": paper.venue,
                        "abstract": paper.abstract,
                        "doi": paper.doi,
                        "article_url": paper.article_url,
                        "download_url": paper.download_url,
                        "filename": paper.filename(suffix=".pdf"),
                        "record": record,
                    }
                )

        return {
            "results": results,
            "source_errors": [
                {"source": source, "message": "该来源暂时无法搜索"}
                for source in errors
            ],
        }

    @router.post("/papers/download")
    async def download_paper(request: PaperDownloadRequest):
        try:
            from paperdl import PaperClient
            from paperdl.modules.utils import PaperInfo
        except ImportError:
            raise HTTPException(503, "论文下载服务尚未安装") from None

        try:
            paper = PaperInfo.fromdict(request.paper)
        except (TypeError, ValueError):
            raise HTTPException(422, "论文记录格式无效") from None

        if paper.source != SOURCE_CLASSES[request.source]:
            raise HTTPException(422, "论文来源与记录不匹配")
        parsed = urlparse(paper.download_url or "")
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.hostname.lower() not in SOURCE_HOSTS[request.source]
        ):
            raise HTTPException(422, "该来源没有可用的官方 PDF 地址")

        output_dir = Path(tempfile.mkdtemp(prefix="daily-consume-paper-"))
        try:
            async with PaperClient(
                [request.source],
                default_init_kwargs={"verbose": False, "show_progress": False},
            ) as client:
                paths = await client.download([paper], output_dir=output_dir, overwrite=True)
            if not paths or not paths[0].is_file():
                raise RuntimeError("下载结果不存在")
            path = paths[0]
            if path.stat().st_size > 80 * 1024 * 1024:
                raise HTTPException(413, "论文文件超过 80 MB，无法通过应用下载")
            return FileResponse(
                path,
                media_type="application/pdf",
                filename=path.name,
                background=BackgroundTask(shutil.rmtree, output_dir, ignore_errors=True),
            )
        except HTTPException:
            shutil.rmtree(output_dir, ignore_errors=True)
            raise
        except Exception:
            shutil.rmtree(output_dir, ignore_errors=True)
            logger.exception("论文 PDF 下载失败，source=%s", request.source)
            raise HTTPException(502, "PDF 下载失败，请打开论文来源页重试") from None

    return router
