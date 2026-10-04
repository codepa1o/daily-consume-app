"""Account-scoped life calendar routes; dates belong to Asia/Shanghai."""
import hashlib
import re
from datetime import date, datetime
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator, model_validator


def journal_today():
    return datetime.now(ZoneInfo('Asia/Shanghai')).date()


def check_date(value):
    if not date(2000, 1, 1) <= value <= date(journal_today().year + 10, 12, 31):
        raise ValueError('日期超出范围')
    return value


class JournalInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    entry_date: date
    kind: Literal['diary', 'memo']
    title: str = Field(default='', max_length=100)
    content: str = Field(default='', max_length=20000)
    is_todo: StrictBool = False
    completed: StrictBool = False

    @field_validator('entry_date', mode='before')
    @classmethod
    def calendar_date(cls, value):
        if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            raise ValueError('请使用日历日期')
        return value

    @field_validator('title', 'content')
    @classmethod
    def trim_text(cls, value):
        return value.strip()

    @model_validator(mode='after')
    def valid_record(self):
        check_date(self.entry_date)
        if self.kind == 'diary':
            if self.entry_date > journal_today() or not self.content or self.is_todo or self.completed:
                raise ValueError('日记需要正文，且不能为未来日期或待办')
        elif not self.title and not self.content:
            raise ValueError('备忘至少填写标题或正文')
        if self.completed and not self.is_todo:
            raise ValueError('普通备忘不能标记完成')
        return self


class JournalCreate(JournalInput):
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')


class JournalUpdate(JournalInput):
    expected_version: int = Field(strict=True, ge=1)


PUBLIC_COLUMNS = 'id, entry_date, kind, title, content, is_todo, completed, version, created_at, updated_at'
FIELDS = ('entry_date', 'kind', 'title', 'content', 'is_todo', 'completed')


def create_journal_router(connect, current_user):
    router = APIRouter(prefix='/journal')
    User = Annotated[dict, Depends(current_user)]

    @router.get('/calendar')
    def calendar(user: User, month: str = Query(pattern=r'^\d{4}-\d{2}$')):
        try:
            start = check_date(date.fromisoformat(month + '-01'))
            end = date(start.year + (start.month == 12), start.month % 12 + 1, 1)
        except ValueError:
            raise HTTPException(422, '月份超出范围或格式不正确')
        with connect() as db:
            rows = db.execute('''SELECT entry_date,
                count(*) FILTER (WHERE kind='diary') AS diaries,
                count(*) FILTER (WHERE kind='memo' AND NOT is_todo) AS memos,
                count(*) FILTER (WHERE is_todo AND NOT completed) AS pending,
                count(*) FILTER (WHERE is_todo AND completed) AS completed
                FROM journal_entries WHERE user_id=%s AND entry_date >= %s AND entry_date < %s
                GROUP BY entry_date ORDER BY entry_date''', (user['id'], start, end)).fetchall()
        return {'days': rows}

    @router.get('/entries')
    def entries(user: User, date: date | None = None, kind: Literal['diary', 'memo'] | None = None,
                q: str = Query(default='', max_length=100),
                limit: int = Query(default=50, ge=1, le=100), offset: int = Query(default=0, ge=0)):
        clauses = ['user_id=%s']
        values = [user['id']]
        if date is not None:
            try:
                check_date(date)
            except ValueError:
                raise HTTPException(422, '日期超出范围')
            clauses.append('entry_date=%s')
            values.append(date)
        if kind:
            clauses.append('kind=%s')
            values.append(kind)
        if q.strip():
            # ponytail: literal ILIKE scans an account's history; index search if this becomes slow.
            keyword = q.strip().replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
            clauses.append('(title ILIKE %s OR content ILIKE %s)')
            values.extend(['%' + keyword + '%'] * 2)
        where = ' AND '.join(clauses)
        order = 'entry_date DESC, created_at DESC, id DESC'
        if date is not None:
            order = 'CASE WHEN is_todo AND NOT completed THEN 0 WHEN completed THEN 2 ELSE 1 END, created_at DESC, id DESC'
        with connect() as db:
            # Keep the count and page in one snapshot during concurrent edits.
            db.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            total = db.execute(f'SELECT count(*) AS n FROM journal_entries WHERE {where}', values).fetchone()['n']
            rows = db.execute(f'''SELECT id, entry_date, kind, title, left(content, 160) AS content,
                is_todo, completed, version, created_at, updated_at FROM journal_entries
                WHERE {where} ORDER BY {order} LIMIT %s OFFSET %s''', [*values, limit, offset]).fetchall()
        return {'items': rows, 'total': total, 'has_more': offset + len(rows) < total}

    @router.get('/entries/{ident}')
    def detail(ident: int, user: User):
        with connect() as db:
            row = db.execute(f'SELECT {PUBLIC_COLUMNS} FROM journal_entries WHERE id=%s AND user_id=%s',
                             (ident, user['id'])).fetchone()
        if not row:
            raise HTTPException(404, '记录不存在或已删除')
        return row

    @router.post('/entries', status_code=201)
    def create(body: JournalCreate, user: User):
        fingerprint = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
        with connect() as db:
            row = db.execute(f'''INSERT INTO journal_entries
                (user_id, entry_date, kind, title, content, is_todo, completed, client_request_id, request_hash)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT (user_id, client_request_id) DO NOTHING RETURNING {PUBLIC_COLUMNS}''',
                (user['id'], *(getattr(body, field) for field in FIELDS), body.client_request_id, fingerprint)).fetchone()
            if row:
                return row
            existing = db.execute(f'SELECT {PUBLIC_COLUMNS}, request_hash FROM journal_entries WHERE user_id=%s AND client_request_id=%s',
                                  (user['id'], body.client_request_id)).fetchone()
            if not existing or existing.pop('request_hash') != fingerprint:
                raise HTTPException(409, '该创建请求已使用，请确认原记录后重试')
            return existing

    def missing_or_conflict(db, ident, owner):
        if not db.execute('SELECT 1 FROM journal_entries WHERE id=%s AND user_id=%s', (ident, owner)).fetchone():
            raise HTTPException(404, '记录不存在或已删除')
        raise HTTPException(409, '记录已在其他位置修改，请查看最新版本后处理')

    @router.put('/entries/{ident}')
    def update(ident: int, body: JournalUpdate, user: User):
        with connect() as db:
            row = db.execute(f'''UPDATE journal_entries SET entry_date=%s, kind=%s, title=%s, content=%s,
                is_todo=%s, completed=%s, version=version+1, updated_at=now()
                WHERE id=%s AND user_id=%s AND version=%s RETURNING {PUBLIC_COLUMNS}''',
                (*(getattr(body, field) for field in FIELDS), ident, user['id'], body.expected_version)).fetchone()
            if not row:
                missing_or_conflict(db, ident, user['id'])
        return row

    @router.delete('/entries/{ident}')
    def delete(ident: int, user: User, expected_version: int = Query(ge=1)):
        with connect() as db:
            row = db.execute('DELETE FROM journal_entries WHERE id=%s AND user_id=%s AND version=%s RETURNING id',
                             (ident, user['id'], expected_version)).fetchone()
            if not row:
                missing_or_conflict(db, ident, user['id'])
        return {'deleted': True}

    return router
