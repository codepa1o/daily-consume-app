"""Daily Consume HTTPS API. Every business query is scoped to its session owner."""
import hashlib
import json
import os
import re
import secrets
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

import psycopg
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator

DSN = os.environ.get('DATABASE_URL', 'dbname=daily_consume user=daily_consume host=/var/run/postgresql')
password_hasher = PasswordHasher()
dummy_password_hash = password_hasher.hash(secrets.token_urlsafe(32))
security = HTTPBearer(auto_error=False)
DEFAULT_MUSCLES = {'胸': 0xffc87962, '背': 0xff6d8fa4, '肩': 0xffc59c4d,
                   '腿': 0xff718665, '手臂': 0xff9b7ca0}


def connect():
    return psycopg.connect(DSN, row_factory=dict_row)


@asynccontextmanager
async def lifespan(_):
    with connect() as db:
        db.execute(Path(__file__).with_name('schema.sql').read_text(encoding='utf-8'))
    yield


app = FastAPI(title='日常 API', version='1.2.0', lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware('http')
async def no_cache(request: Request, call_next):
    response = await call_next(request)
    response.headers['Cache-Control'] = 'no-store'
    return response


@app.exception_handler(RequestValidationError)
async def invalid_input(_, exc):
    # Do not echo submitted passwords or other private request bodies.
    return JSONResponse(status_code=422, content={'detail': '输入格式不正确，请检查日期、数值和必填内容'})


class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')


class Credentials(Input):
    username: str = Field(min_length=3, max_length=32)
    password: SecretStr

    @field_validator('username')
    @classmethod
    def username_format(cls, value):
        value = value.strip()
        if not re.fullmatch(r'[A-Za-z0-9_\-\u4e00-\u9fff]{3,32}', value):
            raise ValueError('用户名格式不正确')
        return value

    @field_validator('password')
    @classmethod
    def password_length(cls, value):
        if not 8 <= len(value.get_secret_value()) <= 128:
            raise ValueError('密码长度为 8–128 位')
        return value


class Registration(Credentials):
    nickname: str = Field(default='', max_length=32)


def current_user(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)]):
    if not credentials or not re.fullmatch(r'[A-Za-z0-9_-]{43}', credentials.credentials):
        raise HTTPException(401, '请先登录')
    token_hash = hashlib.sha256(credentials.credentials.encode()).hexdigest()
    with connect() as db:
        user = db.execute('''SELECT u.id, u.username, u.nickname, u.created_at, s.token_hash
            FROM user_sessions s JOIN users u ON u.id=s.user_id
            WHERE s.token_hash=%s AND s.expires_at>now() AND u.active''', (token_hash,)).fetchone()
    if not user:
        raise HTTPException(401, '登录已过期，请重新登录')
    return user


User = Annotated[dict, Depends(current_user)]


def public_user(user):
    return {key: user[key] for key in ('id', 'username', 'nickname', 'created_at')}


@app.get('/health')
def health():
    with connect() as db:
        db.execute('SELECT 1')
    return {'status': 'ok'}


@app.post('/auth/register', status_code=201)
def register(body: Registration):
    hashed = password_hasher.hash(body.password.get_secret_value())
    try:
        with connect() as db:
            user = db.execute('''INSERT INTO users(username, username_key, password_hash, nickname)
                VALUES (%s,%s,%s,%s) RETURNING id,username,nickname,created_at''',
                (body.username, body.username.casefold(), hashed, body.nickname.strip() or body.username)).fetchone()
            for name, color in DEFAULT_MUSCLES.items():
                db.execute('INSERT INTO workout_muscles VALUES (%s,%s,%s,1)', (user['id'], name, color))
            db.execute('INSERT INTO workout_settings VALUES (%s,3)', (user['id'],))
        return public_user(user)
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, '用户名已被使用')


@app.post('/auth/login')
def login(body: Credentials):
    with connect() as db:
        user = db.execute('SELECT * FROM users WHERE username_key=%s', (body.username.casefold(),)).fetchone()
        try:
            password_hasher.verify(user['password_hash'] if user else dummy_password_hash,
                                   body.password.get_secret_value())
        except VerificationError:
            raise HTTPException(401, '用户名或密码错误')
        if not user or not user['active']:
            raise HTTPException(401, '用户名或密码错误')
        if password_hasher.check_needs_rehash(user['password_hash']):
            db.execute('UPDATE users SET password_hash=%s WHERE id=%s',
                       (password_hasher.hash(body.password.get_secret_value()), user['id']))
        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(timezone.utc) + timedelta(days=30)
        db.execute('DELETE FROM user_sessions WHERE expires_at<=now()')
        db.execute('INSERT INTO user_sessions(token_hash,user_id,expires_at) VALUES (%s,%s,%s)',
                   (hashlib.sha256(token.encode()).hexdigest(), user['id'], expires_at))
    return {'token': token, 'expires_at': expires_at, 'user': public_user(user)}


@app.get('/me')
def me(user: User):
    return public_user(user)


@app.post('/auth/logout')
def logout(user: User):
    with connect() as db:
        db.execute('DELETE FROM user_sessions WHERE token_hash=%s', (user['token_hash'],))
    return {'ok': True}


class DatedInput(Input):
    date: date

    @field_validator('date')
    @classmethod
    def valid_date(cls, value):
        if value < date(2000, 1, 1) or value > datetime.now(ZoneInfo('Asia/Shanghai')).date():
            raise ValueError('日期超出范围')
        return value


class Weight(DatedInput):
    grams: int = Field(ge=20000, le=300000, strict=True)


class Height(DatedInput):
    millimeters: int = Field(ge=800, le=2500, strict=True)


class Meal(DatedInput):
    meal_type: Literal['早餐', '午餐', '晚餐']
    foods: str = Field(min_length=1, max_length=2000)
    expense_cents: int = Field(ge=0, le=10000000000, strict=True)

    @field_validator('foods')
    @classmethod
    def nonempty_foods(cls, value):
        if not value.strip():
            raise ValueError('餐食内容不能为空')
        return value.strip()


def upsert(db, table, owner, row, keys):
    columns = list(row)
    updates = ','.join(f'{c}=EXCLUDED.{c}' for c in columns if c not in keys)
    values = [Jsonb(v) if isinstance(v, (list, dict)) else v for v in row.values()]
    db.execute(f'''INSERT INTO {table}(user_id,{','.join(columns)})
        VALUES ({','.join(['%s']*(len(columns)+1))})
        ON CONFLICT(user_id,{','.join(keys)}) DO UPDATE SET {updates}''', [owner, *values])


@app.get('/weights')
def weights(user: User):
    with connect() as db:
        return db.execute('SELECT date,grams FROM weight_entries WHERE user_id=%s ORDER BY date', (user['id'],)).fetchall()


@app.put('/weights')
def save_weight(body: Weight, user: User):
    with connect() as db:
        upsert(db, 'weight_entries', user['id'], body.model_dump(), ['date'])
    return {'ok': True}


@app.get('/heights')
def heights(user: User):
    with connect() as db:
        return db.execute('SELECT date,millimeters FROM height_entries WHERE user_id=%s ORDER BY date', (user['id'],)).fetchall()


@app.put('/heights')
def save_height(body: Height, user: User):
    with connect() as db:
        upsert(db, 'height_entries', user['id'], body.model_dump(), ['date'])
    return {'ok': True}


@app.get('/meals')
def meals(user: User, start: date, end: date):
    if start > end:
        raise HTTPException(422, '日期范围不正确')
    with connect() as db:
        return db.execute('''SELECT date,meal_type,foods,expense_cents FROM meal_entries
            WHERE user_id=%s AND date BETWEEN %s AND %s ORDER BY date,meal_type''', (user['id'], start, end)).fetchall()


@app.put('/meals')
def save_meal(body: Meal, user: User):
    with connect() as db:
        upsert(db, 'meal_entries', user['id'], body.model_dump(), ['date', 'meal_type'])
    return {'ok': True}


@app.delete('/meals')
def delete_meal(user: User, date: date, meal_type: Literal['早餐', '午餐', '晚餐']):
    with connect() as db:
        db.execute('DELETE FROM meal_entries WHERE user_id=%s AND date=%s AND meal_type=%s', (user['id'], date, meal_type))
    return {'ok': True}


class Muscle(Input):
    name: str = Field(min_length=1, max_length=12)
    color_value: int = Field(ge=0, le=4294967295, strict=True)

    @field_validator('name')
    @classmethod
    def muscle_name(cls, value):
        if not value.strip():
            raise ValueError('部位名称不能为空')
        return value.strip()


class Plan(Input):
    weekday: int = Field(ge=1, le=7, strict=True)
    muscles: list[str] = Field(max_length=100)
    is_rest: int = Field(ge=0, le=1, strict=True)


class Schedule(Input):
    weekly_goal: int = Field(ge=1, le=7, strict=True)
    plans: list[Plan] = Field(min_length=7, max_length=7)


class LogMuscle(Input):
    name: str = Field(min_length=1, max_length=12)
    color: int = Field(ge=0, le=4294967295, strict=True)


class WorkoutLogInput(DatedInput):
    muscles: list[LogMuscle] = Field(min_length=1, max_length=100)


@app.get('/workout/muscles')
def workout_muscles(user: User):
    with connect() as db:
        return db.execute('''SELECT name,color_value,built_in FROM workout_muscles
            WHERE user_id=%s ORDER BY built_in DESC,name''', (user['id'],)).fetchall()


@app.post('/workout/muscles', status_code=201)
def add_muscle(body: Muscle, user: User):
    try:
        with connect() as db:
            duplicate = db.execute('SELECT 1 FROM workout_muscles WHERE user_id=%s AND lower(name)=lower(%s)',
                                   (user['id'], body.name)).fetchone()
            if duplicate:
                raise HTTPException(409, '训练部位已存在')
            db.execute('INSERT INTO workout_muscles VALUES (%s,%s,%s,0)', (user['id'], body.name, body.color_value))
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, '训练部位已存在')
    return {'ok': True}


@app.put('/workout/muscles')
def muscle_color(body: Muscle, user: User):
    with connect() as db:
        changed = db.execute('''UPDATE workout_muscles SET color_value=%s
            WHERE user_id=%s AND name=%s AND built_in=0''', (body.color_value, user['id'], body.name)).rowcount
        if not changed:
            raise HTTPException(404, '自定义部位不存在')
    return {'ok': True}


@app.delete('/workout/muscles')
def delete_muscle(user: User, name: Annotated[str, Query(min_length=1, max_length=12)]):
    with connect() as db:
        # Serialize plan changes with muscle deletion for this account.
        db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
        removed = db.execute('DELETE FROM workout_muscles WHERE user_id=%s AND name=%s AND built_in=0', (user['id'], name)).rowcount
        if not removed:
            raise HTTPException(404, '自定义部位不存在')
        for row in db.execute('SELECT weekday,muscles FROM workout_plans WHERE user_id=%s', (user['id'],)).fetchall():
            db.execute('UPDATE workout_plans SET muscles=%s WHERE user_id=%s AND weekday=%s',
                       (Jsonb([m for m in row['muscles'] if m != name]), user['id'], row['weekday']))
    return {'ok': True}


@app.get('/workout/settings')
def workout_settings(user: User):
    with connect() as db:
        return db.execute('SELECT weekly_goal FROM workout_settings WHERE user_id=%s', (user['id'],)).fetchone()


@app.get('/workout/plans')
def workout_plans(user: User):
    with connect() as db:
        return db.execute('SELECT weekday,muscles,is_rest FROM workout_plans WHERE user_id=%s ORDER BY weekday', (user['id'],)).fetchall()


@app.put('/workout/schedule')
def save_schedule(body: Schedule, user: User):
    if {p.weekday for p in body.plans} != set(range(1, 8)):
        raise HTTPException(422, '请填写完整且不重复的每周计划')
    with connect() as db:
        db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
        names = {r['name'] for r in db.execute('SELECT name FROM workout_muscles WHERE user_id=%s', (user['id'],)).fetchall()}
        for plan in body.plans:
            if len(set(plan.muscles)) != len(plan.muscles) or not set(plan.muscles) <= names:
                raise HTTPException(422, '训练部位不存在或重复')
            row = plan.model_dump()
            if plan.is_rest:
                row['muscles'] = []
            upsert(db, 'workout_plans', user['id'], row, ['weekday'])
        db.execute('UPDATE workout_settings SET weekly_goal=%s WHERE user_id=%s', (body.weekly_goal, user['id']))
    return {'ok': True}


@app.get('/workout/logs')
def workout_logs(user: User, start: date, end: date):
    if start > end:
        raise HTTPException(422, '日期范围不正确')
    with connect() as db:
        return db.execute('''SELECT date,muscles FROM workout_logs WHERE user_id=%s
            AND date BETWEEN %s AND %s ORDER BY date''', (user['id'], start, end)).fetchall()


@app.post('/workout/logs', status_code=201)
def check_in(body: WorkoutLogInput, user: User):
    if body.date != datetime.now(ZoneInfo('Asia/Shanghai')).date():
        raise HTTPException(422, '只能为今天打卡')
    try:
        with connect() as db:
            db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
            plan = db.execute('SELECT is_rest FROM workout_plans WHERE user_id=%s AND weekday=%s',
                              (user['id'], body.date.isoweekday())).fetchone()
            if plan and plan['is_rest']:
                raise HTTPException(409, '休息日不能打卡')
            names = [m.name for m in body.muscles]
            owned = db.execute('SELECT name,color_value FROM workout_muscles WHERE user_id=%s AND name=ANY(%s)',
                               (user['id'], names)).fetchall()
            if len(set(names)) != len(names) or len(owned) != len(names):
                raise HTTPException(422, '训练部位不存在或重复')
            colors = {r['name']: r['color_value'] for r in owned}
            muscles = [{'name': name, 'color': colors[name]} for name in names]
            db.execute('INSERT INTO workout_logs VALUES (%s,%s,%s)', (user['id'], body.date, Jsonb(muscles)))
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, '今天已经打卡')
    return {'ok': True}


@app.delete('/workout/logs')
def undo_check_in(user: User, date: date):
    with connect() as db:
        db.execute('DELETE FROM workout_logs WHERE user_id=%s AND date=%s', (user['id'], date))
    return {'ok': True}


# The whitelist is shared by import validation and SQL construction.
IMPORT_TABLES = {
    'weight_entries': (['date', 'grams'], ['date']),
    'height_entries': (['date', 'millimeters'], ['date']),
    'meal_entries': (['date', 'meal_type', 'foods', 'expense_cents'], ['date', 'meal_type']),
    'workout_muscles': (['name', 'color_value', 'built_in'], ['name']),
    'workout_plans': (['weekday', 'muscles', 'is_rest'], ['weekday']),
    'workout_logs': (['date', 'muscles'], ['date']),
    'workout_settings': (['weekly_goal'], []),
}


class LegacyImport(Input):
    import_id: str = Field(pattern=r'^[a-f0-9]{64}$')
    source_id: str = Field(pattern=r'^[a-f0-9]{64}$')
    tables: dict[str, list[dict]]


def validated_legacy_row(table, original):
    row = dict(original)
    if table == 'workout_settings':
        if row.pop('id', 1) != 1:
            raise ValueError('设置编号不正确')
        if type(row.get('weekly_goal')) is not int or not 1 <= row['weekly_goal'] <= 7:
            raise ValueError('训练目标不正确')
    if 'muscles' in row and isinstance(row['muscles'], str):
        row['muscles'] = json.loads(row['muscles'])
    if table == 'weight_entries':
        row = Weight.model_validate(row).model_dump()
    elif table == 'height_entries':
        row = Height.model_validate(row).model_dump()
    elif table == 'meal_entries':
        row = Meal.model_validate(row).model_dump()
    elif table == 'workout_logs':
        row = WorkoutLogInput.model_validate(row).model_dump(mode='json')
        row['date'] = date.fromisoformat(row['date'])
    elif table == 'workout_plans':
        row = Plan.model_validate(row).model_dump()
        if len(set(row['muscles'])) != len(row['muscles']):
            raise ValueError('训练部位重复')
        if row['is_rest'] and row['muscles']:
            raise ValueError('休息日计划不正确')
    elif table == 'workout_muscles':
        built_in = row.pop('built_in', 0)
        if type(built_in) is not int or built_in not in (0, 1):
            raise ValueError('内置部位标记不正确')
        row = Muscle.model_validate(row).model_dump()
        if built_in and (row['name'] not in DEFAULT_MUSCLES or row['color_value'] != DEFAULT_MUSCLES[row['name']]):
            raise ValueError('内置部位不正确')
        row['built_in'] = built_in
    columns, _ = IMPORT_TABLES[table]
    if set(row) != set(columns):
        raise ValueError('旧数据列不匹配')
    return row


@app.post('/legacy/import')
def import_legacy(body: LegacyImport, user: User):
    if not body.tables or not set(body.tables) <= IMPORT_TABLES.keys() or sum(map(len, body.tables.values())) > 100000:
        raise HTTPException(422, '旧数据表或数量不正确')
    raw = json.dumps(body.tables, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
    if hashlib.sha256((body.source_id + raw).encode()).hexdigest() != body.import_id:
        raise HTTPException(422, '旧数据摘要不匹配，本机数据会保留')
    try:
        tables = {table: [validated_legacy_row(table, row) for row in rows] for table, rows in body.tables.items()}
    except (ValueError, TypeError, KeyError):
        raise HTTPException(422, '旧数据校验失败，本机数据会保留')
    counts = {table: len(rows) for table, rows in tables.items()}
    with connect() as db:
        # Lock the import ID across accounts, including simultaneous first claims.
        db.execute('SELECT pg_advisory_xact_lock(%s)', (int(body.import_id[:15], 16),))
        receipt = db.execute('SELECT user_id,counts FROM legacy_imports WHERE import_id=%s', (body.import_id,)).fetchone()
        if receipt:
            if receipt['user_id'] != user['id']:
                raise HTTPException(409, '这份旧数据已导入其他账号，本机数据会保留')
            if receipt['counts'] != counts:
                raise HTTPException(409, '导入凭据不匹配，本机数据会保留')
            for table, rows in tables.items():
                columns, keys = IMPORT_TABLES[table]
                for row in rows:
                    where = ' AND '.join(['user_id=%s', *(f'{k}=%s' for k in keys)])
                    saved = db.execute(f"SELECT {','.join(columns)} FROM {table} WHERE {where}",
                                       [user['id'], *(row[k] for k in keys)]).fetchone()
                    if saved != row:
                        raise HTTPException(409, '已导入的服务器记录发生变化，本机数据会保留，请先处理冲突')
            return {'import_id': body.import_id, 'counts': receipt['counts']}
        db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
        untouched_goal = db.execute('SELECT weekly_goal FROM workout_settings WHERE user_id=%s', (user['id'],)).fetchone()['weekly_goal'] == 3 and not db.execute(
            'SELECT 1 FROM workout_plans WHERE user_id=%s LIMIT 1', (user['id'],)).fetchone()
        # Registration creates defaults; import may replace only an untouched goal.
        for table, rows in tables.items():
            columns, keys = IMPORT_TABLES[table]
            seen = set()
            for row in rows:
                key = tuple(row[k] for k in keys)
                if key in seen:
                    raise HTTPException(422, '旧数据存在重复记录')
                seen.add(key)
                where = ' AND '.join(['user_id=%s', *(f'{k}=%s' for k in keys)])
                params = [user['id'], *(row[k] for k in keys)]
                current = db.execute(f"SELECT {','.join(columns)} FROM {table} WHERE {where}", params).fetchone()
                if current and current != row:
                    if table == 'workout_settings' and untouched_goal:
                        db.execute('UPDATE workout_settings SET weekly_goal=%s WHERE user_id=%s', (row['weekly_goal'], user['id']))
                    else:
                        raise HTTPException(409, '账号已有不同的同日记录或训练设置，请先处理冲突；本机数据会保留')
                elif not current:
                    values = [Jsonb(row[c]) if isinstance(row[c], list) else row[c] for c in columns]
                    db.execute(f"INSERT INTO {table}(user_id,{','.join(columns)}) VALUES ({','.join(['%s']*(len(columns)+1))})",
                               [user['id'], *values])
                saved = db.execute(f"SELECT {','.join(columns)} FROM {table} WHERE {where}", params).fetchone()
                if saved != row:
                    raise HTTPException(409, '导入核对失败，本机数据会保留')
        db.execute('INSERT INTO legacy_imports(import_id,user_id,counts) VALUES (%s,%s,%s)',
                   (body.import_id, user['id'], Jsonb(counts)))
    return {'import_id': body.import_id, 'counts': counts}
