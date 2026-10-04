"""Shared memories, scoped to the two authenticated members of a space."""
import base64
import binascii
import hashlib
import io
import json
import re
import secrets
from datetime import date, datetime
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Path, Query
from fastapi.responses import Response
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


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


class AnniversaryInput(Input):
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
    display_mode: Literal['grid', 'swipe'] = 'grid'
    photos_base64: list[str] | None = Field(default=None, max_length=9)
    photo_base64: str | None = Field(default=None, max_length=11184812)
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')

    _valid_date = field_validator('memory_date')(SpaceInput.calendar_date.__func__)

    @model_validator(mode='after')
    def valid_photo_set(self):
        if self.photos_base64 is not None and self.photo_base64 is not None:
            raise ValueError('请在一条回忆中使用同一种照片格式')
        photos = self.photos_base64 if self.photos_base64 is not None else [self.photo_base64] if self.photo_base64 else []
        if any(len(photo) > 11184812 for photo in photos):
            raise ValueError('单张照片不能超过 8 MB')
        if sum(map(len, photos)) > 16777216:
            raise ValueError('照片压缩后的合计大小不能超过 12 MB')
        return self


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


def make_grid_cover(thumbnails):
    if len(thumbnails) == 1:
        return thumbnails[0]
    size, gap = 400, 4
    columns = 2 if len(thumbnails) in (2, 4) else 3
    cell = (size - gap * (columns - 1)) // columns
    canvas = Image.new('RGB', (size, size), 'white')
    for position, thumbnail in enumerate(thumbnails):
        with Image.open(io.BytesIO(thumbnail)) as source:
            tile = ImageOps.fit(source.convert('RGB'), (cell, cell), method=Image.Resampling.LANCZOS)
            x = (position % columns) * (cell + gap)
            y = (position // columns) * (cell + gap)
            canvas.paste(tile, (x, y))
    output = io.BytesIO()
    canvas.save(output, 'JPEG', quality=82)
    return output.getvalue()


MEMORY_COLUMNS = '''m.id,m.author_id,u.nickname AS author_name,m.memory_date,
    (m.created_at AT TIME ZONE 'Asia/Shanghai')::date AS published_date,
    m.title,m.content,m.mood,m.display_mode,m.created_at,
    (SELECT count(*)::integer FROM couple_memory_photos p WHERE p.memory_id=m.id) AS photo_count,
    (m.photo IS NOT NULL OR EXISTS(SELECT 1 FROM couple_memory_photos p WHERE p.memory_id=m.id)) AS has_photo'''


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

    @router.put('/space/anniversary')
    def update_anniversary(body: AnniversaryInput, user: User):
        with connect() as db:
            space = space_for(db, user)
            return db.execute('''UPDATE couple_spaces SET since_date=%s
                WHERE id=%s RETURNING since_date''', (body.since_date, space['id'])).fetchone()

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
                WHERE m.space_id=%s ORDER BY m.created_at DESC,m.id DESC LIMIT %s OFFSET %s''',
                (space['id'], limit + 1, offset)).fetchall()
        return {'items': rows[:limit], 'has_more': len(rows) > limit}

    @router.post('/memories', status_code=201)
    def create_memory(body: MemoryInput, user: User):
        with connect() as db:
            space = space_for(db, user)
        # Keep legacy single-photo retries byte-for-byte compatible with 1.3.0 clients.
        fingerprint_body = {
            'memory_date': body.memory_date.isoformat(), 'title': body.title,
            'content': body.content, 'mood': body.mood,
            'photo_base64': body.photo_base64, 'client_request_id': body.client_request_id,
        }
        if body.photos_base64 is not None:
            fingerprint_body['photos_base64'] = body.photos_base64
            fingerprint_body['display_mode'] = body.display_mode
        elif body.display_mode != 'grid':
            fingerprint_body['display_mode'] = body.display_mode
        fingerprint = hashlib.sha256(json.dumps(fingerprint_body, ensure_ascii=False,
            separators=(',', ':')).encode()).hexdigest()
        encoded_photos = body.photos_base64 if body.photos_base64 is not None else [body.photo_base64] if body.photo_base64 else []
        if sum(map(len, encoded_photos)) > 16777216:
            raise HTTPException(422, '一条回忆的照片压缩后总大小不能超过 12 MB')
        prepared_photos = [prepare_photo(encoded) for encoded in encoded_photos]
        thumbnails = [thumb for _, thumb in prepared_photos]
        thumbnail = make_grid_cover(thumbnails) if body.display_mode == 'grid' and thumbnails else (
            thumbnails[0] if thumbnails else None)
        first_photo = prepared_photos[0][0] if prepared_photos else None
        # ponytail: small private albums store bounded JPEGs in PostgreSQL; use object storage at larger scale.
        with connect() as db:
            ident = db.execute('''INSERT INTO couple_memories
                (space_id,author_id,memory_date,title,content,mood,display_mode,photo,thumbnail,client_request_id,request_hash)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(author_id,client_request_id) DO NOTHING RETURNING id''',
                (space['id'], user['id'], body.memory_date, body.title, body.content, body.mood,
                 body.display_mode, first_photo, thumbnail, body.client_request_id, fingerprint)).fetchone()
            if not ident:
                ident = db.execute('''SELECT id,request_hash FROM couple_memories
                    WHERE author_id=%s AND client_request_id=%s''', (user['id'], body.client_request_id)).fetchone()
                if not ident or ident['request_hash'] != fingerprint:
                    raise HTTPException(409, '该保存请求已使用，请刷新后确认回忆是否已保存')
            else:
                for position, (photo, thumb) in enumerate(prepared_photos):
                    db.execute('''INSERT INTO couple_memory_photos(memory_id,position,photo,thumbnail)
                        VALUES (%s,%s,%s,%s)''', (ident['id'], position, photo, thumb))
            return memory_for(db, ident['id'], user)

    def photo_response(ident, user, position, thumbnail):
        with connect() as db:
            memory_for(db, ident, user)
            column = 'thumbnail' if thumbnail else 'photo'
            row = db.execute(f'''SELECT {column} AS data FROM couple_memory_photos
                WHERE memory_id=%s AND position=%s''', (ident, position)).fetchone()
        if not row:
            raise HTTPException(404, '这张照片不存在或无权访问')
        return Response(bytes(row['data']), media_type='image/jpeg', headers={'X-Content-Type-Options': 'nosniff'})

    @router.get('/memories/{ident}/photos')
    def get_thumbnails(ident: int, user: User):
        with connect() as db:
            memory_for(db, ident, user)
            rows = db.execute('''SELECT position,thumbnail FROM couple_memory_photos
                WHERE memory_id=%s ORDER BY position''', (ident,)).fetchall()
        if not rows:
            raise HTTPException(404, '这条回忆没有照片')
        return {'items': [{'position': row['position'],
            'thumbnail_base64': base64.b64encode(bytes(row['thumbnail'])).decode('ascii')} for row in rows]}

    @router.get('/memories/{ident}/photos/{position}')
    def get_photo_at(ident: int, user: User, position: Annotated[int, Path(ge=0, le=8)],
                     thumbnail: bool = True):
        return photo_response(ident, user, position, thumbnail)

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
                WHERE m.space_id=%s
                  AND m.created_at >= (%s::date::timestamp AT TIME ZONE 'Asia/Shanghai')
                  AND m.created_at < ((%s::date + 1)::timestamp AT TIME ZONE 'Asia/Shanghai')
                  AND (m.photo IS NOT NULL OR EXISTS(SELECT 1 FROM couple_memory_photos p WHERE p.memory_id=m.id))
                ORDER BY m.author_id,m.created_at DESC,m.id DESC''',
                (space['id'], memory_date, memory_date)).fetchall()
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
