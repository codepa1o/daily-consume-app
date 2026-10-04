"""Shared memories, scoped to the two authenticated members of a space."""
import base64
import binascii
import hashlib
import io
import re
import secrets
from datetime import date, datetime
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import Response
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, field_validator


def today():
    return datetime.now(ZoneInfo('Asia/Shanghai')).date()


class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')

    @field_validator('*', mode='before')
    @classmethod
    def trim(cls, value):
        return value.strip() if isinstance(value, str) else value

    @field_validator('since_date', 'memory_date', mode='before', check_fields=False)
    @classmethod
    def date_string(cls, value):
        if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            raise ValueError('请使用日历日期')
        return value


class SpaceInput(Input):
    title: str = Field(default='两个人的小窝', min_length=1, max_length=60)
    since_date: date

    @field_validator('since_date')
    @classmethod
    def calendar_date(cls, value):
        if not date(2000, 1, 1) <= value <= today():
            raise ValueError('日期超出范围')
        return value


class InviteInput(Input):
    code: str = Field(pattern=r'^[A-Z0-9]{12}$')

    @field_validator('code', mode='before')
    @classmethod
    def uppercase(cls, value):
        return value.strip().upper() if isinstance(value, str) else value


class MemoryInput(Input):
    memory_date: date
    title: str = Field(min_length=1, max_length=100)
    content: str = Field(default='', max_length=5000)
    mood: Literal['', '开心', '平静', '想你', '疲惫', '难过'] = ''
    photo_base64: str | None = Field(default=None, max_length=11184812)
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')

    _valid_date = field_validator('memory_date')(SpaceInput.calendar_date.__func__)


class CommentInput(Input):
    content: str = Field(min_length=1, max_length=1000)
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')


class ReactionInput(Input):
    emoji: Literal['❤️', '抱抱', '想你', '开心'] | None = None


def prepare_photo(encoded):
    if encoded is None:
        return None, None
    try:
        raw = base64.b64decode(encoded, validate=True)
        if not raw or len(raw) > 8 * 1024 * 1024:
            raise ValueError('size')
        with Image.open(io.BytesIO(raw), formats=('JPEG', 'PNG', 'WEBP')) as source:
            if source.width * source.height > 24_000_000 or getattr(source, 'is_animated', False):
                raise ValueError('dimensions')
            source.load()
            image = ImageOps.exif_transpose(source).convert('RGBA')
            image.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
            canvas = Image.new('RGB', image.size, 'white')
            canvas.paste(image, mask=image.getchannel('A'))
            full = io.BytesIO()
            # Fresh output strips EXIF, including GPS, and never serves the uploaded original.
            canvas.save(full, 'JPEG', quality=88)
            canvas.thumbnail((400, 400), Image.Resampling.LANCZOS)
            thumb = io.BytesIO()
            canvas.save(thumb, 'JPEG', quality=80)
        return full.getvalue(), thumb.getvalue()
    except (ValueError, OSError, binascii.Error, UnidentifiedImageError, Image.DecompressionBombError):
        raise HTTPException(422, '请选择 8 MB 以内的静态 JPG、PNG 或 WebP 照片（最多 2400 万像素）')


MEMORY_COLUMNS = '''m.id,m.author_id,u.nickname AS author_name,m.memory_date,m.title,
    m.content,m.mood,(m.photo IS NOT NULL) AS has_photo,m.created_at'''


def create_couple_router(connect, current_user):
    router = APIRouter(prefix='/couple')
    User = Annotated[dict, Depends(current_user)]

    def space_for(db, user):
        space = db.execute('''SELECT s.id,s.title,s.since_date,s.created_by FROM couple_spaces s
            JOIN couple_members m ON m.space_id=s.id WHERE m.user_id=%s''', (user['id'],)).fetchone()
        if not space:
            raise HTTPException(404, '请先创建或加入情侣空间')
        return space

    def memory_for(db, ident, user):
        row = db.execute(f'''SELECT {MEMORY_COLUMNS} FROM couple_memories m
            JOIN users u ON u.id=m.author_id JOIN couple_members member ON member.space_id=m.space_id
            WHERE m.id=%s AND member.user_id=%s''', (ident, user['id'])).fetchone()
        if not row:
            raise HTTPException(404, '回忆不存在或无权访问')
        return row

    @router.get('/space')
    def get_space(user: User):
        with connect() as db:
            row = db.execute('''SELECT s.id,s.title,s.since_date,s.created_by FROM couple_spaces s
                JOIN couple_members m ON m.space_id=s.id WHERE m.user_id=%s''', (user['id'],)).fetchone()
            if row:
                row['members'] = db.execute('''SELECT u.id,u.nickname FROM couple_members m
                    JOIN users u ON u.id=m.user_id WHERE m.space_id=%s ORDER BY m.slot''', (row['id'],)).fetchall()
        return row

    @router.post('/space', status_code=201)
    def create_space(body: SpaceInput, user: User):
        try:
            with connect() as db:
                db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
                if db.execute('SELECT 1 FROM couple_members WHERE user_id=%s', (user['id'],)).fetchone():
                    raise HTTPException(409, '你已拥有情侣空间，请刷新查看')
                row = db.execute('''INSERT INTO couple_spaces(title,since_date,created_by)
                    VALUES (%s,%s,%s) RETURNING id,title,since_date,created_by''',
                    (body.title, body.since_date, user['id'])).fetchone()
                db.execute('INSERT INTO couple_members VALUES (%s,%s,1)', (user['id'], row['id']))
                row['members'] = [{'id': user['id'], 'nickname': user['nickname']}]
            return row
        except psycopg.errors.UniqueViolation:
            raise HTTPException(409, '账号已加入其他空间，请刷新')

    @router.post('/invite')
    def invite(user: User):
        code = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(12))
        with connect() as db:
            space = space_for(db, user)
            db.execute('SELECT id FROM couple_spaces WHERE id=%s FOR UPDATE', (space['id'],))
            if db.execute('SELECT count(*) AS n FROM couple_members WHERE space_id=%s', (space['id'],)).fetchone()['n'] != 1:
                raise HTTPException(409, '两个人已经到齐了')
            row = db.execute('''UPDATE couple_spaces SET invite_hash=%s,invite_expires_at=now()+interval '7 days'
                WHERE id=%s RETURNING invite_expires_at''', (hashlib.sha256(code.encode()).hexdigest(), space['id'])).fetchone()
        return {'code': code, 'expires_at': row['invite_expires_at']}

    def invited_space(db, body, user, *, lock=False):
        row = db.execute('''SELECT id,title,since_date,created_by FROM couple_spaces
            WHERE invite_hash=%s AND invite_expires_at>now()''' + (' FOR UPDATE' if lock else ''),
            (hashlib.sha256(body.code.encode()).hexdigest(),)).fetchone()
        if not row or row['created_by'] == user['id']:
            raise HTTPException(404, '邀请码无效、已使用或已过期')
        if db.execute('SELECT 1 FROM couple_members WHERE user_id=%s', (user['id'],)).fetchone():
            raise HTTPException(409, '你已拥有情侣空间')
        return row

    @router.post('/invite/preview')
    def preview_invite(body: InviteInput, user: User):
        with connect() as db:
            row = invited_space(db, body, user)
            row['inviter'] = db.execute('SELECT nickname FROM users WHERE id=%s', (row.pop('created_by'),)).fetchone()['nickname']
        return row

    @router.post('/join')
    def join(body: InviteInput, user: User):
        try:
            with connect() as db:
                # Serialize different invitations accepted by the same account, then lock the target space.
                db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
                row = invited_space(db, body, user, lock=True)
                db.execute('INSERT INTO couple_members VALUES (%s,%s,2)', (user['id'], row['id']))
                db.execute('UPDATE couple_spaces SET invite_hash=NULL,invite_expires_at=NULL WHERE id=%s', (row['id'],))
            return {'joined': True}
        except psycopg.errors.UniqueViolation:
            raise HTTPException(409, '账号或空间已绑定，请刷新后重试')

    @router.get('/memories')
    def memories(user: User, offset: int = Query(default=0, ge=0), limit: int = Query(default=30, ge=1, le=100)):
        with connect() as db:
            db.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            space = space_for(db, user)
            rows = db.execute(f'''SELECT {MEMORY_COLUMNS} FROM couple_memories m JOIN users u ON u.id=m.author_id
                WHERE m.space_id=%s ORDER BY m.memory_date DESC,m.id DESC LIMIT %s OFFSET %s''',
                (space['id'], limit + 1, offset)).fetchall()
        return {'items': rows[:limit], 'has_more': len(rows) > limit}

    @router.post('/memories', status_code=201)
    def create_memory(body: MemoryInput, user: User):
        with connect() as db:
            space = space_for(db, user)
        fingerprint = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
        photo, thumbnail = prepare_photo(body.photo_base64)
        # ponytail: small private albums store bounded JPEGs in PostgreSQL; use object storage at larger scale.
        with connect() as db:
            ident = db.execute('''INSERT INTO couple_memories
                (space_id,author_id,memory_date,title,content,mood,photo,thumbnail,client_request_id,request_hash)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(author_id,client_request_id) DO NOTHING RETURNING id''',
                (space['id'], user['id'], body.memory_date, body.title, body.content, body.mood,
                 photo, thumbnail, body.client_request_id, fingerprint)).fetchone()
            if not ident:
                ident = db.execute('''SELECT id,request_hash FROM couple_memories
                    WHERE author_id=%s AND client_request_id=%s''', (user['id'], body.client_request_id)).fetchone()
                if not ident or ident['request_hash'] != fingerprint:
                    raise HTTPException(409, '该保存请求已使用，请刷新后确认回忆是否已保存')
            return memory_for(db, ident['id'], user)

    @router.get('/pair')
    def pair(user: User, memory_date: date = Query(alias='date')):
        try:
            SpaceInput.calendar_date(memory_date)
        except ValueError:
            raise HTTPException(422, '日期超出范围')
        with connect() as db:
            space = space_for(db, user)
            rows = db.execute(f'''SELECT DISTINCT ON (m.author_id) {MEMORY_COLUMNS}
                FROM couple_memories m JOIN users u ON u.id=m.author_id
                WHERE m.space_id=%s AND m.memory_date=%s AND m.photo IS NOT NULL
                ORDER BY m.author_id,m.id DESC''', (space['id'], memory_date)).fetchall()
        return {'items': rows}

    @router.get('/memories/{ident}')
    def detail(ident: int, user: User):
        with connect() as db:
            row = memory_for(db, ident, user)
            row['comments'] = db.execute('''SELECT c.id,c.author_id,u.nickname AS author_name,c.content,c.created_at
                FROM couple_comments c JOIN users u ON u.id=c.author_id WHERE c.memory_id=%s ORDER BY c.id''', (ident,)).fetchall()
            row['reactions'] = db.execute('''SELECT r.user_id,u.nickname AS author_name,r.emoji
                FROM couple_reactions r JOIN users u ON u.id=r.user_id WHERE r.memory_id=%s ORDER BY r.user_id''', (ident,)).fetchall()
        return row

    @router.get('/memories/{ident}/photo')
    def get_photo(ident: int, user: User, thumbnail: bool = True):
        with connect() as db:
            memory_for(db, ident, user)
            column = 'thumbnail' if thumbnail else 'photo'
            row = db.execute(f'SELECT {column} AS data FROM couple_memories WHERE id=%s', (ident,)).fetchone()
        if not row or row['data'] is None:
            raise HTTPException(404, '这条回忆没有照片')
        return Response(bytes(row['data']), media_type='image/jpeg', headers={'X-Content-Type-Options': 'nosniff'})

    @router.delete('/memories/{ident}')
    def delete_memory(ident: int, user: User):
        with connect() as db:
            row = memory_for(db, ident, user)
            if row['author_id'] != user['id']:
                raise HTTPException(403, '只能删除自己发布的回忆')
            db.execute('DELETE FROM couple_memories WHERE id=%s AND author_id=%s', (ident, user['id']))
        return {'deleted': True}

    @router.post('/memories/{ident}/comments', status_code=201)
    def comment(ident: int, body: CommentInput, user: User):
        with connect() as db:
            memory_for(db, ident, user)
            row = db.execute('''INSERT INTO couple_comments(memory_id,author_id,content,client_request_id)
                VALUES (%s,%s,%s,%s) ON CONFLICT(author_id,client_request_id) DO NOTHING RETURNING id''',
                (ident, user['id'], body.content, body.client_request_id)).fetchone()
            if not row:
                row = db.execute('''SELECT id,memory_id,content FROM couple_comments
                    WHERE author_id=%s AND client_request_id=%s''', (user['id'], body.client_request_id)).fetchone()
                if not row or row['memory_id'] != ident or row['content'] != body.content:
                    raise HTTPException(409, '该留言请求已使用，请刷新后确认')
        return {'id': row['id']}

    @router.put('/memories/{ident}/reaction')
    def react(ident: int, body: ReactionInput, user: User):
        with connect() as db:
            memory_for(db, ident, user)
            if body.emoji is None:
                db.execute('DELETE FROM couple_reactions WHERE memory_id=%s AND user_id=%s', (ident, user['id']))
            else:
                db.execute('''INSERT INTO couple_reactions VALUES (%s,%s,%s)
                    ON CONFLICT(memory_id,user_id) DO UPDATE SET emoji=excluded.emoji''', (ident, user['id'], body.emoji))
        return {'saved': True}

    return router
