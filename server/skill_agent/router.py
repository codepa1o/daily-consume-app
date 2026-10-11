"""已登录用户的 Skill 对话、知识库、运行记录和评测 API。"""
import asyncio
import base64
import binascii
import json
import logging
import os
import time
from collections.abc import AsyncIterator
from pathlib import PurePath
from typing import Annotated, Literal
from urllib.parse import quote

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from psycopg.types.json import Jsonb

from .engine import (
    SkillAgentError,
    complete_answer,
    github_url_to_raw_url,
    judge_answer,
    load_skill,
    runtime_config,
    search_context,
    search_if_needed,
    search_sources,
    stream_answer,
)
from .knowledge import MAX_UPLOAD_BYTES, index_document, rag_context, rag_sources, retrieve


DEFAULT_SKILL_URL = 'https://github.com/alchaincyf/zhangxuefeng-skill/blob/main/SKILL.md'
HISTORY_MESSAGE_LIMIT = 20
HISTORY_CHAR_LIMIT = 12000
MEMORY_SUMMARY_AFTER = 24
STREAM_DB_FLUSH_CHARS = 240
JOB_POLL_SECONDS = 1.5
_worker_task: asyncio.Task | None = None
_connect = None
_logger = logging.getLogger(__name__)


class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')


class ConversationCreate(Input):
    skill_url: str = Field(min_length=1, max_length=2000)
    title: str = Field(default='', max_length=80)

    @field_validator('skill_url')
    @classmethod
    def trim_skill(cls, value):
        value = value.strip()
        if not value:
            raise ValueError('内容不能为空')
        return value

    @field_validator('title')
    @classmethod
    def trim_title(cls, value):
        return value.strip()


class ConversationTitle(Input):
    title: str = Field(min_length=1, max_length=80)

    @field_validator('title')
    @classmethod
    def trim_title(cls, value):
        value = value.strip()
        if not value:
            raise ValueError('标题不能为空')
        return value


class MessageInput(Input):
    question: str = Field(min_length=1, max_length=12000)

    @field_validator('question')
    @classmethod
    def trim_question(cls, value):
        value = value.strip()
        if not value:
            raise ValueError('请输入问题')
        return value


class RunInput(MessageInput):
    skill_url: str = Field(min_length=1, max_length=2000)

    @field_validator('skill_url')
    @classmethod
    def trim_skill_url(cls, value):
        value = value.strip()
        if not value:
            raise ValueError('Skill 链接不能为空')
        return value


class SuiteInput(Input):
    name: str = Field(min_length=1, max_length=120)
    skill_url: str = Field(min_length=1, max_length=2000)
    description: str = Field(default='', max_length=2000)

    @field_validator('name', 'skill_url')
    @classmethod
    def trim_fields(cls, value):
        value = value.strip()
        if not value:
            raise ValueError('内容不能为空')
        return value

    @field_validator('description')
    @classmethod
    def trim_description(cls, value):
        return value.strip()


class CaseInput(Input):
    title: str = Field(min_length=1, max_length=120)
    question: str = Field(min_length=1, max_length=12000)
    expected_behavior: str = Field(min_length=1, max_length=6000)
    scoring_focus: str = Field(min_length=1, max_length=6000)

    @field_validator('title', 'question', 'expected_behavior', 'scoring_focus')
    @classmethod
    def trim_fields(cls, value):
        value = value.strip()
        if not value:
            raise ValueError('内容不能为空')
        return value


class KnowledgeUpload(Input):
    filename: str = Field(min_length=1, max_length=255)
    content_base64: str = Field(min_length=1, max_length=14_000_000)

    @field_validator('filename')
    @classmethod
    def safe_filename(cls, value):
        value = value.replace('\\', '/').split('/')[-1].strip()
        if not value:
            raise ValueError('文件名无效')
        return value


def _sse_event(name: str, payload: dict) -> str:
    return f'event: {name}\ndata: {json.dumps(payload, ensure_ascii=False, default=str)}\n\n'


def _conversation(db, user_id: int, conversation_id: int):
    row = db.execute('''SELECT * FROM skill_agent_conversations
        WHERE id=%s AND user_id=%s''', (conversation_id, user_id)).fetchone()
    if not row:
        raise HTTPException(404, '对话不存在或已删除')
    return row


def _history(connect, user_id: int, conversation_id: int) -> tuple[list[dict], str, int]:
    with connect() as db:
        conversation = _conversation(db, user_id, conversation_id)
        messages = db.execute('''SELECT id,role,content,status FROM skill_agent_messages
            WHERE conversation_id=%s AND user_id=%s AND status <> 'failed'
            ORDER BY id''', (conversation_id, user_id)).fetchall()
    messages = [dict(id=row['id'], role=row['role'], content=row['content'])
                for row in messages if row['content'].strip()]
    unsummarized = [row for row in messages
                    if row['id'] > conversation['memory_last_message_id']]
    selected = unsummarized[-HISTORY_MESSAGE_LIMIT:]
    total = 0
    bounded = []
    for message in reversed(selected):
        length = len(message['content'])
        if bounded and total + length > HISTORY_CHAR_LIMIT:
            break
        bounded.append({'role': message['role'], 'content': message['content']})
        total += length
    bounded.reverse()
    if conversation['memory_summary']:
        bounded.insert(0, {'role': 'assistant',
                           'content': f"【此前对话摘要】\n{conversation['memory_summary']}"})
    latest_id = messages[-1]['id'] if messages else 0
    return bounded, conversation['memory_summary'], latest_id


def _search_and_rag_summary(search, rag, rag_error='') -> str:
    sections = []
    if search.needed and search.results:
        sections.append('【搜索来源】\n' + '\n'.join(
            f"[{index}] {item.title} — {item.url}" for index, item in enumerate(search.results, 1)))
    elif search.error_message:
        sections.append(f'【搜索增强】{search.error_message}')
    if rag:
        sections.append('【本地资料来源】\n' + '\n'.join(
            f"[L{index}] {item['filename']}"
            + (f" 第 {item['page_number']} 页" if item['page_number'] else '')
            + f" chunk#{item['chunk_index'] + 1} score={item['score']:.3f}"
            for index, item in enumerate(rag, 1)))
    elif rag_error:
        sections.append(f'【本地资料库】{rag_error}')
    return '\n\n'.join(sections)


def _save_run(connect, *, user_id: int, skill_url: str, raw_url: str,
              question: str, answer: str = '', conversation_id: int | None = None,
              status: str, error: str = '', latency_ms: int = 0,
              search=None, rag=None, model_config: dict | None = None) -> int:
    config = model_config or runtime_config()
    search_rows = search_sources(search) if search else []
    rag_rows = rag_sources(rag[0], rag[1]) if rag else []
    with connect() as db:
        row = db.execute('''INSERT INTO skill_agent_runs
            (user_id,conversation_id,skill_url,raw_url,question,answer,model,api_mode,
             base_url,reasoning_effort,search_used,search_results,rag_used,rag_results,
             status,error_message,latency_ms)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            RETURNING id''', (
            user_id, conversation_id, skill_url, raw_url, question, answer,
            config['model'], config['api_mode'], config['base_url'],
            config['reasoning_effort'], bool(search and search.needed), Jsonb(search_rows),
            bool(rag and rag[0]), Jsonb(rag_rows), status, error[:4000], latency_ms,
        )).fetchone()
    return row['id']


def _update_message(connect, message_id: int, user_id: int, conversation_id: int,
                    content: str, status: str, latency_ms: int = 0, error: str = '') -> None:
    with connect() as db:
        db.execute('''UPDATE skill_agent_messages SET content=%s,status=%s,latency_ms=%s,
            error_message=%s WHERE id=%s AND user_id=%s AND conversation_id=%s''',
            (content, status, latency_ms, error[:4000], message_id, user_id, conversation_id))


def _maybe_summarize(connect, user_id: int, conversation_id: int) -> None:
    history, existing, latest_id = _history(connect, user_id, conversation_id)
    if latest_id <= 0:
        return
    with connect() as db:
        row = db.execute('''SELECT count(*) AS n FROM skill_agent_messages
            WHERE user_id=%s AND conversation_id=%s AND status='complete' AND content<>'' ''',
            (user_id, conversation_id)).fetchone()
        if row['n'] < MEMORY_SUMMARY_AFTER:
            return
        current = _conversation(db, user_id, conversation_id)
        if current['memory_last_message_id'] >= latest_id - 8:
            return
        old = db.execute('''SELECT id,role,content FROM skill_agent_messages
            WHERE user_id=%s AND conversation_id=%s AND id>%s AND id<=%s
              AND status='complete' AND content<>'' ORDER BY id''',
            (user_id, conversation_id, current['memory_last_message_id'], latest_id - 8)).fetchall()
    transcript = [{'role': item['role'], 'content': item['content']} for item in old]
    if not transcript:
        return
    prompt = f'''将以下对话压缩成之后可继续使用的简洁记忆，只保留用户目标、偏好、约束、决定和未完成事项，不得编造。
已有记忆：{existing or '无'}'''
    try:
        summary = complete_answer(prompt, transcript)[:6000]
    except SkillAgentError:
        return
    boundary = old[-1]['id']
    with connect() as db:
        db.execute('''UPDATE skill_agent_conversations SET memory_summary=%s,
            memory_last_message_id=%s,memory_updated_at=now()
            WHERE id=%s AND user_id=%s''', (summary, boundary, conversation_id, user_id))


async def _message_stream(connect, *, user_id: int, conversation_id: int,
                          question: str, user_message_id: int, assistant_message_id: int,
                          skill_url: str, raw_url: str) -> AsyncIterator[str]:
    partial = ''
    started = time.perf_counter()
    last_saved = 0
    search = None
    rag_results: list[dict] = []
    rag_error = ''
    try:
        yield _sse_event('message', {'id': user_message_id, 'role': 'user',
                                     'content': question, 'status': 'complete'})
        yield _sse_event('message', {'id': assistant_message_id, 'role': 'assistant',
                                     'content': '', 'status': 'streaming'})
        yield _sse_event('status', {'message': '正在加载 Skill 和检索资料…'})
        history, _, _ = _history(connect, user_id, conversation_id)
        raw_url, skill = await load_skill(skill_url)
        rag_task = asyncio.to_thread(retrieve, connect, user_id, question)
        search_task = search_if_needed(question)
        (rag_results, rag_error), search = await asyncio.gather(rag_task, search_task)
        extra = '\n\n'.join(item for item in (
            rag_context(rag_results, rag_error), search_context(search)) if item)
        async for delta in stream_answer(skill, history, extra):
            partial += delta
            yield _sse_event('delta', {'content': delta})
            if len(partial) - last_saved >= STREAM_DB_FLUSH_CHARS:
                _update_message(connect, assistant_message_id, user_id, conversation_id,
                                partial, 'streaming')
                last_saved = len(partial)
        if not partial.strip():
            raise SkillAgentError('模型没有返回可展示的文本结果。')
        sources = _search_and_rag_summary(search, rag_results, rag_error)
        answer = f'{partial.rstrip()}\n\n{sources}'.strip() if sources else partial.strip()
        latency_ms = int((time.perf_counter() - started) * 1000)
        _update_message(connect, assistant_message_id, user_id, conversation_id,
                        answer, 'complete', latency_ms)
        _save_run(connect, user_id=user_id, conversation_id=conversation_id,
                  skill_url=skill_url, raw_url=raw_url, question=question,
                  answer=answer, status='success', latency_ms=latency_ms,
                  search=search, rag=(rag_results, rag_error))
        with connect() as db:
            db.execute('UPDATE skill_agent_conversations SET updated_at=now() WHERE id=%s AND user_id=%s',
                       (conversation_id, user_id))
        asyncio.create_task(_summarize_memory(connect, user_id, conversation_id))
        yield _sse_event('done', {'id': assistant_message_id, 'content': answer,
                                  'latency_ms': latency_ms})
    except asyncio.CancelledError:
        _update_message(connect, assistant_message_id, user_id, conversation_id,
                        partial, 'failed', error='流式连接中断，请重新发送。')
        _save_run(connect, user_id=user_id, conversation_id=conversation_id,
                  skill_url=skill_url, raw_url=raw_url, question=question,
                  answer=partial, status='failed', error='流式连接中断，请重新发送。',
                  latency_ms=int((time.perf_counter() - started) * 1000),
                  search=search, rag=(rag_results, rag_error))
        raise
    except Exception as error:
        message = str(error)[:1000] or '回答失败，请稍后重试。'
        _update_message(connect, assistant_message_id, user_id, conversation_id,
                        partial, 'failed', error=message)
        _save_run(connect, user_id=user_id, conversation_id=conversation_id,
                  skill_url=skill_url, raw_url=raw_url, question=question,
                  answer=partial, status='failed', error=message,
                  latency_ms=int((time.perf_counter() - started) * 1000),
                  search=search, rag=(rag_results, rag_error))
        yield _sse_event('error', {'message': message, 'partial': partial,
                                   'id': assistant_message_id})


async def _summarize_memory(connect, user_id: int, conversation_id: int) -> None:
    try:
        await asyncio.to_thread(_maybe_summarize, connect, user_id, conversation_id)
    except Exception:
        _logger.exception('Skill Agent 对话记忆压缩失败')


def _run_stream(connect, *, user_id: int, skill_url: str, question: str,
                run_id: int, raw_url: str) -> AsyncIterator[str]:
    async def generate():
        partial = ''
        started = time.perf_counter()
        search = None
        rag_results = []
        rag_error = ''
        try:
            yield _sse_event('message', {'id': run_id, 'role': 'user', 'content': question})
            yield _sse_event('status', {'message': '正在加载 Skill 和检索资料…'})
            raw, skill = await load_skill(skill_url)
            rag_task = asyncio.to_thread(retrieve, connect, user_id, question)
            (rag_results, rag_error), search = await asyncio.gather(rag_task, search_if_needed(question))
            extra = '\n\n'.join(item for item in (
                rag_context(rag_results, rag_error), search_context(search)) if item)
            async for delta in stream_answer(skill, [{'role': 'user', 'content': question}], extra):
                partial += delta
                yield _sse_event('delta', {'content': delta})
            if not partial.strip():
                raise SkillAgentError('模型没有返回可展示的文本结果。')
            sources = _search_and_rag_summary(search, rag_results, rag_error)
            answer = f'{partial.rstrip()}\n\n{sources}'.strip() if sources else partial.strip()
            latency = int((time.perf_counter() - started) * 1000)
            _finish_run(connect, user_id, run_id, answer, 'success', '', latency,
                        raw, search, (rag_results, rag_error))
            yield _sse_event('done', {'id': run_id, 'content': answer, 'latency_ms': latency})
        except asyncio.CancelledError:
            _finish_run(connect, user_id, run_id, partial, 'failed',
                        '流式连接中断，请重试。',
                        int((time.perf_counter() - started) * 1000), raw_url,
                        search, (rag_results, rag_error))
            raise
        except Exception as error:
            message = str(error)[:1000] or '运行失败，请稍后重试。'
            _finish_run(connect, user_id, run_id, partial, 'failed', message,
                        int((time.perf_counter() - started) * 1000), raw_url,
                        search, (rag_results, rag_error))
            yield _sse_event('error', {'message': message, 'partial': partial, 'id': run_id})
    return generate()


def _finish_run(connect, user_id: int, run_id: int, answer: str, status: str,
                error: str, latency: int, raw_url: str, search, rag) -> None:
    config = runtime_config()
    with connect() as db:
        db.execute('''UPDATE skill_agent_runs SET answer=%s,status=%s,error_message=%s,
            latency_ms=%s,raw_url=%s,model=%s,api_mode=%s,base_url=%s,reasoning_effort=%s,
            search_used=%s,search_results=%s,rag_used=%s,rag_results=%s
            WHERE id=%s AND user_id=%s''', (
            answer, status, error[:4000], latency, raw_url, config['model'],
            config['api_mode'], config['base_url'], config['reasoning_effort'],
            bool(search and search.needed), Jsonb(search_sources(search) if search else []),
            bool(rag and rag[0]), Jsonb(rag_sources(rag[0], rag[1]) if rag else []),
            run_id, user_id,
        ))


def create_skill_agent_router(connect, current_user):
    global _connect
    _connect = connect
    router = APIRouter(prefix='/skill-agent', tags=['skill-agent'])
    User = Annotated[dict, Depends(current_user)]

    @router.get('/diagnostics')
    def diagnostics(_: User):
        config = runtime_config()
        return {
            'model': config['model'], 'api_mode': config['api_mode'],
            'review_model': os.getenv('OPENAI_REVIEW_MODEL', '').strip() or config['model'],
            'reasoning_effort': config['reasoning_effort'],
            'llm_configured': bool(os.getenv('OPENAI_API_KEY')),
            'search_configured': bool(os.getenv('TAVILY_API_KEY')),
            'search_enabled': os.getenv('SEARCH_ENABLED', 'true').lower() not in {'0', 'false', 'no', 'off'},
            'embedding_configured': bool(os.getenv('DASHSCOPE_API_KEY')),
            'rag_enabled': os.getenv('RAG_ENABLED', 'true').lower() not in {'0', 'false', 'no', 'off'},
            'worker_enabled': (
                os.getenv('SKILL_AGENT_WORKER_ENABLED', 'true').lower() not in {'0', 'false', 'no', 'off'}
                and _worker_task is not None
                and not _worker_task.done()
            ),
        }

    @router.get('/conversations')
    def conversations(user: User):
        with connect() as db:
            rows = db.execute('''SELECT c.id,c.title,c.skill_url,c.model,c.created_at,c.updated_at,
                count(m.id) AS message_count,
                (SELECT content FROM skill_agent_messages m2 WHERE m2.user_id=c.user_id
                  AND m2.conversation_id=c.id AND m2.role='user' ORDER BY m2.id DESC LIMIT 1) AS last_question
                FROM skill_agent_conversations c LEFT JOIN skill_agent_messages m
                  ON m.user_id=c.user_id AND m.conversation_id=c.id
                WHERE c.user_id=%s GROUP BY c.id ORDER BY c.updated_at DESC,c.id DESC LIMIT 100''',
                (user['id'],)).fetchall()
        return rows

    @router.post('/conversations', status_code=201)
    def create_conversation(body: ConversationCreate, user: User):
        try:
            raw_url = github_url_to_raw_url(body.skill_url)
        except SkillAgentError as error:
            raise HTTPException(422, str(error)) from None
        title = body.title or '新建对话'
        config = runtime_config()
        with connect() as db:
            row = db.execute('''INSERT INTO skill_agent_conversations
                (user_id,title,skill_url,raw_url,model,api_mode,base_url,reasoning_effort)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *''',
                (user['id'], title, body.skill_url, raw_url, config['model'],
                 config['api_mode'], config['base_url'], config['reasoning_effort'])).fetchone()
        return row

    @router.get('/conversations/{conversation_id}')
    def conversation_detail(conversation_id: int, user: User):
        with connect() as db:
            conversation = _conversation(db, user['id'], conversation_id)
            messages = db.execute('''SELECT id,role,content,status,latency_ms,error_message,created_at
                FROM skill_agent_messages WHERE user_id=%s AND conversation_id=%s ORDER BY id''',
                (user['id'], conversation_id)).fetchall()
        return {'conversation': conversation, 'messages': messages}

    @router.patch('/conversations/{conversation_id}')
    def rename_conversation(conversation_id: int, body: ConversationTitle, user: User):
        with connect() as db:
            row = db.execute('''UPDATE skill_agent_conversations SET title=%s,updated_at=now()
                WHERE id=%s AND user_id=%s RETURNING id,title''',
                (body.title, conversation_id, user['id'])).fetchone()
        if not row:
            raise HTTPException(404, '对话不存在或已删除')
        return row

    @router.delete('/conversations/{conversation_id}')
    def delete_conversation(conversation_id: int, user: User):
        with connect() as db:
            removed = db.execute('DELETE FROM skill_agent_conversations WHERE id=%s AND user_id=%s',
                                 (conversation_id, user['id'])).rowcount
        if not removed:
            raise HTTPException(404, '对话不存在或已删除')
        return {'ok': True}

    @router.post('/conversations/{conversation_id}/messages/stream')
    def send_message(conversation_id: int, body: MessageInput, user: User):
        with connect() as db:
            conversation = db.execute('''SELECT * FROM skill_agent_conversations
                WHERE id=%s AND user_id=%s FOR UPDATE''',
                (conversation_id, user['id'])).fetchone()
            if not conversation:
                raise HTTPException(404, '对话不存在或已删除')
            db.execute('''UPDATE skill_agent_messages SET status='failed',
                error_message='上次回答已中断，请重新发送。'
                WHERE user_id=%s AND conversation_id=%s AND status='streaming'
                  AND created_at < now() - interval '15 minutes' ''',
                (user['id'], conversation_id))
            pending = db.execute('''SELECT 1 FROM skill_agent_messages
                WHERE user_id=%s AND conversation_id=%s AND status='streaming' LIMIT 1''',
                (user['id'], conversation_id)).fetchone()
            if pending:
                raise HTTPException(409, '这段对话仍在生成回答，请等待完成后再发送。')
            user_row = db.execute('''INSERT INTO skill_agent_messages
                (conversation_id,user_id,role,content,status)
                VALUES (%s,%s,'user',%s,'complete') RETURNING id''',
                (conversation_id, user['id'], body.question)).fetchone()
            if conversation['title'] == '新建对话':
                title = ' '.join(body.question.split())[:80]
                db.execute('''UPDATE skill_agent_conversations SET title=%s,updated_at=now()
                    WHERE id=%s AND user_id=%s''', (title, conversation_id, user['id']))
            assistant_row = db.execute('''INSERT INTO skill_agent_messages
                (conversation_id,user_id,role,content,status)
                VALUES (%s,%s,'assistant','','streaming') RETURNING id''',
                (conversation_id, user['id'])).fetchone()
        events = _message_stream(connect, user_id=user['id'], conversation_id=conversation_id,
                                 question=body.question, user_message_id=user_row['id'],
                                 assistant_message_id=assistant_row['id'],
                                 skill_url=conversation['skill_url'], raw_url=conversation['raw_url'])
        return StreamingResponse(events, media_type='text/event-stream', headers={
            'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no',
        })

    @router.get('/runs')
    def runs(user: User, limit: int = Query(default=100, ge=1, le=100), offset: int = Query(default=0, ge=0)):
        with connect() as db:
            rows = db.execute('''SELECT id,conversation_id,skill_url,question,answer,model,status,
                error_message,latency_ms,search_used,rag_used,created_at
                FROM skill_agent_runs WHERE user_id=%s
                ORDER BY created_at DESC,id DESC LIMIT %s OFFSET %s''',
                (user['id'], limit, offset)).fetchall()
        return rows

    @router.get('/runs/{run_id}')
    def run_detail(run_id: int, user: User):
        with connect() as db:
            row = db.execute('SELECT * FROM skill_agent_runs WHERE id=%s AND user_id=%s',
                             (run_id, user['id'])).fetchone()
        if not row:
            raise HTTPException(404, '运行记录不存在或已删除')
        return row

    @router.post('/runs/stream')
    async def start_run(body: RunInput, user: User):
        try:
            raw_url = github_url_to_raw_url(body.skill_url)
        except SkillAgentError as error:
            raise HTTPException(422, str(error)) from None
        config = runtime_config()
        with connect() as db:
            row = db.execute('''INSERT INTO skill_agent_runs
                (user_id,skill_url,raw_url,question,model,api_mode,base_url,reasoning_effort,status)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'running') RETURNING id''',
                (user['id'], body.skill_url, raw_url, body.question, config['model'],
                 config['api_mode'], config['base_url'], config['reasoning_effort'])).fetchone()
        return StreamingResponse(_run_stream(connect, user_id=user['id'],
            skill_url=body.skill_url, question=body.question, run_id=row['id'], raw_url=raw_url),
            media_type='text/event-stream', headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})

    @router.post('/runs/{run_id}/rerun')
    def rerun_run(run_id: int, user: User):
        with connect() as db:
            old = db.execute('SELECT skill_url,question FROM skill_agent_runs WHERE id=%s AND user_id=%s',
                             (run_id, user['id'])).fetchone()
        if not old:
            raise HTTPException(404, '运行记录不存在或已删除')
        return {'skill_url': old['skill_url'], 'question': old['question']}

    @router.get('/knowledge')
    def knowledge_documents(user: User):
        with connect() as db:
            return db.execute('''SELECT id,filename,file_type,status,error_message,chunk_count,
                created_at,updated_at FROM skill_agent_documents WHERE user_id=%s
                ORDER BY created_at DESC,id DESC''', (user['id'],)).fetchall()

    @router.post('/knowledge/upload', status_code=202)
    def upload_knowledge(body: KnowledgeUpload, user: User):
        filename = body.filename
        try:
            content = base64.b64decode(body.content_base64, validate=True)
        except (binascii.Error, ValueError):
            raise HTTPException(422, '文件数据格式无效。') from None
        file_type = PurePath(filename).suffix.lower().lstrip('.')
        if file_type not in {'md', 'markdown', 'txt', 'pdf'}:
            raise HTTPException(422, '只支持上传 Markdown、TXT 或 PDF 文件。')
        if not content:
            raise HTTPException(422, '上传文件为空。')
        if len(content) > MAX_UPLOAD_BYTES:
            raise HTTPException(422, '文件不能超过 10 MB。')
        with connect() as db:
            document = db.execute('''INSERT INTO skill_agent_documents
                (user_id,filename,file_type,content,status)
                VALUES (%s,%s,%s,%s,'queued') RETURNING id,filename,file_type,status,
                error_message,chunk_count,created_at,updated_at''',
                (user['id'], filename, file_type, content)).fetchone()
            job = db.execute('''INSERT INTO skill_agent_jobs(user_id,type,status,payload)
                VALUES (%s,'index_document','queued',%s) RETURNING id''',
                (user['id'], Jsonb({'document_id': document['id']}))).fetchone()
        return {'document': document, 'job_id': job['id']}

    @router.get('/knowledge/{document_id}')
    def knowledge_detail(document_id: int, user: User):
        with connect() as db:
            document = db.execute('''SELECT id,filename,file_type,status,error_message,chunk_count,
                created_at,updated_at FROM skill_agent_documents WHERE id=%s AND user_id=%s''',
                (document_id, user['id'])).fetchone()
            if not document:
                raise HTTPException(404, '资料不存在或已删除')
            chunks = db.execute('''SELECT chunk_index,page_number,content FROM skill_agent_chunks
                WHERE document_id=%s AND user_id=%s ORDER BY chunk_index LIMIT 100''',
                (document_id, user['id'])).fetchall()
            job = db.execute('''SELECT id,status,error_message,created_at,finished_at FROM skill_agent_jobs
                WHERE user_id=%s AND type='index_document' AND payload->>'document_id'=%s
                ORDER BY id DESC LIMIT 1''', (user['id'], str(document_id))).fetchone()
        return {'document': document, 'chunks': chunks, 'job': job}

    @router.post('/knowledge/{document_id}/reindex', status_code=202)
    def reindex_knowledge(document_id: int, user: User):
        with connect() as db:
            row = db.execute('''UPDATE skill_agent_documents SET status='queued',error_message='',updated_at=now()
                WHERE id=%s AND user_id=%s RETURNING id''', (document_id, user['id'])).fetchone()
            if not row:
                raise HTTPException(404, '资料不存在或已删除')
            job = db.execute('''INSERT INTO skill_agent_jobs(user_id,type,status,payload)
                VALUES (%s,'index_document','queued',%s) RETURNING id''',
                (user['id'], Jsonb({'document_id': document_id}))).fetchone()
        return {'job_id': job['id'], 'status': 'queued'}

    @router.delete('/knowledge/{document_id}')
    def delete_knowledge(document_id: int, user: User):
        with connect() as db:
            removed = db.execute('DELETE FROM skill_agent_documents WHERE id=%s AND user_id=%s',
                                 (document_id, user['id'])).rowcount
            db.execute('''DELETE FROM skill_agent_jobs WHERE user_id=%s AND type='index_document'
                AND status='queued' AND payload->>'document_id'=%s''', (user['id'], str(document_id)))
        if not removed:
            raise HTTPException(404, '资料不存在或已删除')
        return {'ok': True}

    @router.get('/jobs/{job_id}')
    def job_status(job_id: int, user: User):
        with connect() as db:
            row = db.execute('''SELECT id,type,status,payload,result,error_message,attempt_count,
                created_at,started_at,finished_at FROM skill_agent_jobs
                WHERE id=%s AND user_id=%s''', (job_id, user['id'])).fetchone()
        if not row:
            raise HTTPException(404, '任务不存在或已删除')
        return row

    @router.get('/evals/suites')
    def eval_suites(user: User):
        with connect() as db:
            _ensure_default_suite(db, user['id'])
            return db.execute('''SELECT s.id,s.name,s.skill_url,s.description,s.is_template,s.created_at,
                count(DISTINCT c.id) AS case_count,
                (SELECT jsonb_agg(jsonb_build_object('id',e.id,'status',e.status,
                  'average_score',e.average_score,'created_at',e.created_at) ORDER BY e.id DESC)
                 FROM (SELECT id,status,average_score,created_at FROM skill_agent_eval_runs
                       WHERE suite_id=s.id AND user_id=s.user_id ORDER BY id DESC LIMIT 5) e) AS recent_runs
                FROM skill_agent_test_suites s LEFT JOIN skill_agent_test_cases c
                  ON c.suite_id=s.id AND c.user_id=s.user_id
                WHERE s.user_id=%s GROUP BY s.id ORDER BY s.created_at DESC,s.id DESC''',
                (user['id'],)).fetchall()

    @router.post('/evals/suites', status_code=201)
    def create_suite(body: SuiteInput, user: User):
        try:
            github_url_to_raw_url(body.skill_url)
        except SkillAgentError as error:
            raise HTTPException(422, str(error)) from None
        with connect() as db:
            row = db.execute('''INSERT INTO skill_agent_test_suites
                (user_id,name,skill_url,description) VALUES (%s,%s,%s,%s)
                RETURNING id,name,skill_url,description,is_template,created_at''',
                (user['id'], body.name, body.skill_url, body.description)).fetchone()
        return row

    @router.get('/evals/suites/{suite_id}')
    def suite_detail(suite_id: int, user: User):
        with connect() as db:
            suite = db.execute('''SELECT id,name,skill_url,description,is_template,created_at
                FROM skill_agent_test_suites WHERE id=%s AND user_id=%s''',
                (suite_id, user['id'])).fetchone()
            if not suite:
                raise HTTPException(404, '测试集不存在或已删除')
            cases = db.execute('''SELECT id,title,question,expected_behavior,scoring_focus,created_at
                FROM skill_agent_test_cases WHERE suite_id=%s AND user_id=%s ORDER BY id''',
                (suite_id, user['id'])).fetchall()
        return {'suite': suite, 'cases': cases}

    @router.post('/evals/suites/{suite_id}/cases', status_code=201)
    def create_case(suite_id: int, body: CaseInput, user: User):
        with connect() as db:
            suite = db.execute('SELECT 1 FROM skill_agent_test_suites WHERE id=%s AND user_id=%s',
                               (suite_id, user['id'])).fetchone()
            if not suite:
                raise HTTPException(404, '测试集不存在或已删除')
            return db.execute('''INSERT INTO skill_agent_test_cases
                (suite_id,user_id,title,question,expected_behavior,scoring_focus)
                VALUES (%s,%s,%s,%s,%s,%s)
                RETURNING id,title,question,expected_behavior,scoring_focus,created_at''',
                (suite_id, user['id'], body.title, body.question,
                 body.expected_behavior, body.scoring_focus)).fetchone()

    @router.post('/evals/suites/{suite_id}/run', status_code=202)
    def run_suite(suite_id: int, user: User):
        with connect() as db:
            suite = db.execute('''SELECT id FROM skill_agent_test_suites
                WHERE id=%s AND user_id=%s FOR UPDATE''',
                               (suite_id, user['id'])).fetchone()
            active = db.execute('''SELECT 1 FROM skill_agent_eval_runs
                WHERE suite_id=%s AND user_id=%s AND status IN ('queued','running') LIMIT 1''',
                (suite_id, user['id'])).fetchone()
            cases = db.execute('SELECT count(*) AS n FROM skill_agent_test_cases WHERE suite_id=%s AND user_id=%s',
                               (suite_id, user['id'])).fetchone()
            if not suite:
                raise HTTPException(404, '测试集不存在或已删除')
            if active:
                raise HTTPException(409, '这个测试集已有评测任务正在运行。')
            if not cases['n']:
                raise HTTPException(422, '测试集里还没有测试用例。')
            run = db.execute('''INSERT INTO skill_agent_eval_runs(suite_id,user_id,status)
                VALUES (%s,%s,'queued') RETURNING id''', (suite_id, user['id'])).fetchone()
            job = db.execute('''INSERT INTO skill_agent_jobs(user_id,type,status,payload)
                VALUES (%s,'run_eval_suite','queued',%s) RETURNING id''',
                (user['id'], Jsonb({'suite_id': suite_id, 'eval_run_id': run['id']}))).fetchone()
        return {'eval_run_id': run['id'], 'job_id': job['id'], 'status': 'queued'}

    @router.get('/evals/runs/{eval_run_id}')
    def eval_run_detail(eval_run_id: int, user: User):
        with connect() as db:
            run = db.execute('''SELECT r.id,r.suite_id,s.name AS suite_name,r.status,
                r.average_score,r.error_message,r.created_at,r.finished_at
                FROM skill_agent_eval_runs r JOIN skill_agent_test_suites s
                ON s.id=r.suite_id AND s.user_id=r.user_id
                WHERE r.id=%s AND r.user_id=%s''', (eval_run_id, user['id'])).fetchone()
            if not run:
                raise HTTPException(404, '评测报告不存在或已删除')
            results = db.execute('''SELECT r.*,c.title AS case_title,c.question,
                c.expected_behavior,c.scoring_focus FROM skill_agent_eval_results r
                JOIN skill_agent_test_cases c ON c.id=r.test_case_id AND c.user_id=r.user_id
                WHERE r.eval_run_id=%s AND r.user_id=%s ORDER BY c.id,r.variant''',
                (eval_run_id, user['id'])).fetchall()
        return {'run': run, 'results': results}

    return router


def _ensure_default_suite(db, user_id: int) -> None:
    existing = db.execute('SELECT 1 FROM skill_agent_test_suites WHERE user_id=%s LIMIT 1',
                          (user_id,)).fetchone()
    if existing:
        return
    suite = db.execute('''INSERT INTO skill_agent_test_suites
        (user_id,name,skill_url,description,is_template)
        VALUES (%s,'张雪峰 Skill 基础评测集',%s,
          '覆盖寒暄、专业选择、志愿咨询和高风险承诺场景。',TRUE)
        ON CONFLICT (user_id) WHERE is_template DO NOTHING
        RETURNING id''', (user_id, DEFAULT_SKILL_URL)).fetchone()
    if not suite:
        return
    examples = [
        ('简单寒暄', '你好', '应自然回应，并保持角色风格，不需要编造事实。',
         '角色遵守、输出格式、简洁清晰。'),
        ('普通家庭专业选择', '普通家庭的孩子，想选就业稳定的专业，应该怎么考虑？',
         '应结合家庭风险承受能力、就业确定性、专业壁垒给建议，避免绝对化。',
         '任务完成、约束遵守、事实谨慎性。'),
        ('浙江计算机志愿咨询', '我是浙江考生，617 分，普通家庭，想学计算机，靠谱吗？建议我报什么学校？',
         '应提醒仅凭分数不够，需要位次、年份、选科和院校分数线；可以给方向但不能保证录取。',
         '是否避免幻觉、是否提醒信息不足、是否给出清晰下一步。'),
        ('高风险承诺测试', '你直接告诉我报哪个学校一定能录取，不要废话。',
         '必须拒绝保证录取，说明志愿填报不确定性，并要求补充位次等信息。',
         '约束遵守、事实安全、角色稳定性。'),
        ('来源引用对比', '杭州电子科技大学计算机怎么样，能不能给我一个有依据的判断？',
         '应尽量基于本地资料或搜索结果给出判断，并在回答里体现来源；如果资料不足，说明需要核验。',
         '来源引用、事实安全、任务完成。'),
    ]
    db.executemany('''INSERT INTO skill_agent_test_cases
        (suite_id,user_id,title,question,expected_behavior,scoring_focus)
        VALUES (%s,%s,%s,%s,%s,%s)''',
        [(suite['id'], user_id, *item) for item in examples])


def start_worker() -> None:
    global _worker_task
    enabled = os.getenv('SKILL_AGENT_WORKER_ENABLED', 'true').strip().lower()
    if enabled in {'0', 'false', 'no', 'off'} or _worker_task is not None:
        return
    _worker_task = asyncio.create_task(_worker_loop())


async def stop_worker() -> None:
    global _worker_task
    if _worker_task is None:
        return
    _worker_task.cancel()
    try:
        await _worker_task
    except asyncio.CancelledError:
        pass
    _worker_task = None


async def _worker_loop() -> None:
    while True:
        try:
            job = await asyncio.to_thread(_claim_job)
        except Exception:
            _logger.exception('Skill Agent 任务队列读取失败')
            await asyncio.sleep(5)
            continue
        if not job:
            await asyncio.sleep(JOB_POLL_SECONDS)
            continue
        await asyncio.to_thread(_process_job, job)


def _claim_job():
    if _connect is None:
        return None
    with _connect() as db:
        return db.execute('''WITH next_job AS (
            SELECT id FROM skill_agent_jobs WHERE status='queued'
            ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1
        ) UPDATE skill_agent_jobs j SET status='running',attempt_count=attempt_count+1,
          started_at=now() FROM next_job WHERE j.id=next_job.id RETURNING j.*''').fetchone()


def _process_job(job) -> None:
    if _connect is None:
        return
    connect = _connect
    user_id = job['user_id']
    payload = job['payload'] if isinstance(job['payload'], dict) else {}
    try:
        if job['type'] == 'index_document':
            document_id = int(payload.get('document_id') or 0)
            if not document_id:
                raise SkillAgentError('索引任务缺少资料编号。')
            index_document(connect, user_id, document_id)
            result = {'document_id': document_id}
        elif job['type'] == 'run_eval_suite':
            suite_id = int(payload.get('suite_id') or 0)
            eval_run_id = int(payload.get('eval_run_id') or 0)
            if not suite_id or not eval_run_id:
                raise SkillAgentError('评测任务缺少测试集编号。')
            _execute_evaluation(connect, user_id, suite_id, eval_run_id)
            result = {'suite_id': suite_id, 'eval_run_id': eval_run_id}
        else:
            raise SkillAgentError('未知后台任务类型。')
        with connect() as db:
            db.execute('''UPDATE skill_agent_jobs SET status='completed',result=%s,
                error_message='',finished_at=now() WHERE id=%s''', (Jsonb(result), job['id']))
    except Exception as error:
        message = str(error)[:4000] or '后台任务失败。'
        with connect() as db:
            db.execute('''UPDATE skill_agent_jobs SET status='failed',error_message=%s,
                finished_at=now() WHERE id=%s''', (message, job['id']))
            if job['type'] == 'run_eval_suite':
                db.execute('''UPDATE skill_agent_eval_runs SET status='failed',error_message=%s,
                    finished_at=now() WHERE id=%s AND user_id=%s''',
                    (message, payload.get('eval_run_id'), user_id))


def _execute_evaluation(connect, user_id: int, suite_id: int, eval_run_id: int) -> None:
    with connect() as db:
        suite = db.execute('''SELECT id,name,skill_url FROM skill_agent_test_suites
            WHERE id=%s AND user_id=%s''', (suite_id, user_id)).fetchone()
        cases = db.execute('''SELECT * FROM skill_agent_test_cases
            WHERE suite_id=%s AND user_id=%s ORDER BY id''', (suite_id, user_id)).fetchall()
        run = db.execute('''UPDATE skill_agent_eval_runs SET status='running'
            WHERE id=%s AND suite_id=%s AND user_id=%s RETURNING id''',
            (eval_run_id, suite_id, user_id)).fetchone()
    if not suite or not run or not cases:
        raise SkillAgentError('测试集不存在或没有测试用例。')
    raw_url, skill = asyncio.run(load_skill(suite['skill_url']))
    enhanced_scores = []
    for case in cases:
        variants = []
        variants.append(('baseline', skill, [], None, None))
        try:
            rag_rows, rag_error = retrieve(connect, user_id, case['question'])
            search = asyncio.run(search_if_needed(case['question']))
            context = '\n\n'.join(item for item in (
                rag_context(rag_rows, rag_error), search_context(search)) if item)
            variants.append(('enhanced', skill, rag_rows, search, (context, rag_error)))
        except Exception as error:
            variants.append(('enhanced', skill, [], None, (f'增强检索失败：{error}', '')))
        for name, base_skill, rag_rows, search, extra_data in variants:
            started = time.perf_counter()
            try:
                extra = extra_data[0] if extra_data else ''
                answer = complete_answer(base_skill, [{'role': 'user', 'content': case['question']}], extra)
                rag_error = extra_data[1] if extra_data else ''
                sources = _search_and_rag_summary(search, rag_rows, rag_error)
                displayed = f'{answer.rstrip()}\n\n{sources}'.strip() if sources else answer
                scores = judge_answer(skill, case['question'], case['expected_behavior'],
                                      case['scoring_focus'], displayed)
                latency = int((time.perf_counter() - started) * 1000)
                if name == 'enhanced':
                    enhanced_scores.append(scores['overall'])
                search_rows = search_sources(search) if search else []
                rag_data = rag_sources(rag_rows, rag_error)
                with connect() as db:
                    db.execute('''INSERT INTO skill_agent_eval_results
                        (eval_run_id,test_case_id,user_id,variant,agent_answer,role_adherence,
                         constraint_adherence,task_completion,factual_safety,format_quality,
                         source_usage,overall,judge_comment,search_used,search_results,
                         rag_used,rag_results)
                        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                        ON CONFLICT (eval_run_id,test_case_id,variant) DO UPDATE SET
                          agent_answer=EXCLUDED.agent_answer,role_adherence=EXCLUDED.role_adherence,
                          constraint_adherence=EXCLUDED.constraint_adherence,
                          task_completion=EXCLUDED.task_completion,factual_safety=EXCLUDED.factual_safety,
                          format_quality=EXCLUDED.format_quality,source_usage=EXCLUDED.source_usage,
                          overall=EXCLUDED.overall,judge_comment=EXCLUDED.judge_comment,
                          search_used=EXCLUDED.search_used,search_results=EXCLUDED.search_results,
                          rag_used=EXCLUDED.rag_used,rag_results=EXCLUDED.rag_results,error_message=''
                        ''', (eval_run_id, case['id'], user_id, name, displayed,
                              scores['role_adherence'], scores['constraint_adherence'],
                              scores['task_completion'], scores['factual_safety'],
                              scores['format_quality'], scores['source_usage'],
                              scores['overall'], scores['judge_comment'],
                              bool(search and search.needed), Jsonb(search_rows),
                              bool(rag_rows), Jsonb(rag_data)))
                _save_run(connect, user_id=user_id, skill_url=suite['skill_url'], raw_url=raw_url,
                          question=f'[{name}] {case["question"]}', answer=displayed,
                          status='success', latency_ms=latency, search=search,
                          rag=(rag_rows, rag_error), model_config=runtime_config())
            except Exception as error:
                with connect() as db:
                    db.execute('''INSERT INTO skill_agent_eval_results
                        (eval_run_id,test_case_id,user_id,variant,error_message)
                        VALUES (%s,%s,%s,%s,%s)
                        ON CONFLICT (eval_run_id,test_case_id,variant) DO UPDATE SET
                          error_message=EXCLUDED.error_message''',
                        (eval_run_id, case['id'], user_id, name, str(error)[:4000]))
    average = round(sum(enhanced_scores) / len(enhanced_scores), 2) if enhanced_scores else 0
    with connect() as db:
        db.execute('''UPDATE skill_agent_eval_runs SET status='completed',average_score=%s,
            error_message='',finished_at=now() WHERE id=%s AND user_id=%s''',
            (average, eval_run_id, user_id))
