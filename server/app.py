"""Daily Consume HTTPS API. Every business query is scoped to its session owner."""
import base64
import asyncio
import hashlib
import json
import logging
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

import psycopg
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from pydantic import BaseModel, ConfigDict, Field, SecretStr, ValidationError, field_validator, model_validator

from database import DSN
from journal import create_journal_router
from couple import create_couple_router, prepare_photo
from travel import create_travel_router
from research import create_research_router
from chatbot import create_chatbot_router
from skill_agent.router import (
    create_skill_agent_router,
    start_worker as start_skill_agent_worker,
    stop_worker as stop_skill_agent_worker,
)

password_hasher = PasswordHasher()
dummy_password_hash = password_hasher.hash(secrets.token_urlsafe(32))
security = HTTPBearer(auto_error=False)
reminder_logger = logging.getLogger('daily_consume.pomodoro_reminders')
_wechat_token_lock = threading.Lock()
_wechat_access_token_value = ''
_wechat_access_token_expires_at = 0.0
_pomodoro_reminder_task = None
DEFAULT_MUSCLES = {'胸': 0xffc87962, '背': 0xff6d8fa4, '肩': 0xffc59c4d,
                   '腿': 0xff718665, '手臂': 0xff9b7ca0}


def connect():
    return psycopg.connect(DSN, row_factory=dict_row)


SERVER_DIR = Path(__file__).resolve().parent
PROMPT_DIR = SERVER_DIR / 'prompts'
if not PROMPT_DIR.is_dir():
    PROMPT_DIR = SERVER_DIR.parent / 'prompts'


def load_ai_prompt(name):
    try:
        prompt = (PROMPT_DIR / name).read_text(encoding='utf-8').strip()
    except OSError:
        raise HTTPException(500, 'AI 提示词文件无法读取') from None
    if not prompt:
        raise HTTPException(500, 'AI 提示词文件为空')
    return prompt


def plain_ai_text(value):
    value = re.sub(r'(?m)^[ \t]{0,3}#{1,6}[ \t]*', '', value)
    value = re.sub(r'\*\*(.+?)\*\*|__(.+?)__',
                   lambda match: match.group(1) or match.group(2), value)
    return value.strip()


app = FastAPI(title='日常 API', version='1.4.8',
              docs_url=None, redoc_url=None, openapi_url=None)

web_origins = [
    origin.strip()
    for origin in os.environ.get('WEB_ALLOWED_ORIGINS', '').split(',')
    if origin.strip()
]
if web_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=web_origins,
        allow_credentials=False,
        allow_methods=['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        allow_headers=['Accept', 'Authorization', 'Content-Type'],
    )


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


class WechatCode(Input):
    code: str = Field(min_length=1, max_length=256)


def wechat_identity(code):
    app_id = os.environ.get('WECHAT_MINIPROGRAM_APPID', '').strip()
    app_secret = os.environ.get('WECHAT_MINIPROGRAM_APPSECRET', '').strip()
    if not app_id or not app_secret:
        raise HTTPException(503, '微信登录尚未配置')
    query = urllib.parse.urlencode({
        'appid': app_id,
        'secret': app_secret,
        'js_code': code,
        'grant_type': 'authorization_code',
    })
    request = urllib.request.Request(
        f'https://api.weixin.qq.com/sns/jscode2session?{query}',
        headers={'Accept': 'application/json'},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise HTTPException(502, '微信登录服务暂不可用，请重试') from None
    if not isinstance(result, dict) or result.get('errcode') or not isinstance(result.get('openid'), str):
        raise HTTPException(401, '微信登录凭证无效，请重试')
    return app_id, result['openid']


def _wechat_access_token():
    global _wechat_access_token_value, _wechat_access_token_expires_at
    with _wechat_token_lock:
        if _wechat_access_token_value and time.monotonic() < _wechat_access_token_expires_at:
            return _wechat_access_token_value
        app_id = os.environ.get('WECHAT_MINIPROGRAM_APPID', '').strip()
        app_secret = os.environ.get('WECHAT_MINIPROGRAM_APPSECRET', '').strip()
        if not app_id or not app_secret:
            raise RuntimeError('微信服务端未配置')
        query = urllib.parse.urlencode({
            'grant_type': 'client_credential', 'appid': app_id, 'secret': app_secret,
        })
        request = urllib.request.Request(
            f'https://api.weixin.qq.com/cgi-bin/token?{query}',
            headers={'Accept': 'application/json'},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read())
        token = result.get('access_token') if isinstance(result, dict) else None
        if not isinstance(token, str) or not token:
            raise RuntimeError('微信服务端令牌获取失败')
        _wechat_access_token_value = token
        _wechat_access_token_expires_at = time.monotonic() + max(60, int(result.get('expires_in', 7200)) - 300)
        return token


def _pomodoro_template_data(row):
    raw_fields = os.environ.get('WECHAT_POMODORO_TEMPLATE_FIELDS', '')
    try:
        fields = json.loads(raw_fields) if raw_fields else {
            'thing1': 'task', 'time2': 'deadline', 'thing3': 'phase',
        }
    except ValueError:
        raise RuntimeError('番茄钟订阅模板字段配置无效') from None
    if not isinstance(fields, dict) or not fields:
        raise RuntimeError('番茄钟订阅模板字段尚未配置')
    phase = {
        'focus': '专注时间结束',
        'shortBreak': '短休息结束',
        'longBreak': '长休息结束',
    }[row['phase']]
    values = {
        'task': row['task_title'] or '番茄钟',
        'phase': phase,
        'deadline': row['trigger_at'].astimezone(ZoneInfo('Asia/Shanghai')).strftime('%Y-%m-%d %H:%M'),
    }
    if any(key not in values or not isinstance(field, str) for field, key in fields.items()):
        raise RuntimeError('番茄钟订阅模板字段映射无效')
    return {field: {'value': values[key][:20]} for field, key in fields.items()}


def _claim_pomodoro_reminders():
    with connect() as db:
        rows = db.execute('''SELECT r.*,w.openid FROM pomodoro_reminders r
            JOIN wechat_identities w ON w.app_id=r.app_id AND w.user_id=r.user_id
            WHERE r.status='pending' AND r.trigger_at<=now()
            ORDER BY r.trigger_at LIMIT 20 FOR UPDATE OF r SKIP LOCKED''').fetchall()
        for row in rows:
            db.execute("UPDATE pomodoro_reminders SET status='sending' WHERE id=%s", (row['id'],))
    return rows


def _finish_pomodoro_reminder(reminder_id, *, sent=False, message='', permanent=False):
    with connect() as db:
        if sent:
            db.execute("""UPDATE pomodoro_reminders SET status='sent',sent_at=now(),
                error_message='',attempt_count=attempt_count+1 WHERE id=%s""", (reminder_id,))
            return
        db.execute('''UPDATE pomodoro_reminders SET
            status=CASE WHEN %s OR attempt_count>=2 THEN 'failed' ELSE 'pending' END,
            trigger_at=CASE WHEN %s OR attempt_count>=2 THEN trigger_at ELSE now()+interval '1 minute' END,
            error_message=%s,attempt_count=attempt_count+1 WHERE id=%s''',
            (permanent, permanent, message[:300], reminder_id))


def _send_pomodoro_reminder(row):
    try:
        token = _wechat_access_token()
        payload = {
            'touser': row['openid'],
            'template_id': row['template_id'],
            'page': 'pages/focus/index',
            'data': _pomodoro_template_data(row),
        }
        request = urllib.request.Request(
            f'https://api.weixin.qq.com/cgi-bin/message/subscribe/send?access_token={urllib.parse.quote(token)}',
            data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
            headers={'Content-Type': 'application/json', 'Accept': 'application/json'},
            method='POST',
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read())
        if isinstance(result, dict) and result.get('errcode') == 0:
            _finish_pomodoro_reminder(row['id'], sent=True)
            return
        code = result.get('errcode') if isinstance(result, dict) else None
        permanent = code in (43101, 40003, 40037)
        _finish_pomodoro_reminder(row['id'], message=f'微信订阅消息发送失败（{code or "unknown"}）', permanent=permanent)
    except Exception:
        reminder_logger.warning('番茄钟订阅提醒发送失败，稍后重试')
        _finish_pomodoro_reminder(row['id'], message='微信订阅消息服务暂不可用')


async def _pomodoro_reminder_worker():
    while True:
        try:
            rows = await asyncio.to_thread(_claim_pomodoro_reminders)
            for row in rows:
                await asyncio.to_thread(_send_pomodoro_reminder, row)
        except asyncio.CancelledError:
            raise
        except Exception:
            reminder_logger.warning('番茄钟订阅提醒队列读取失败')
        await asyncio.sleep(15)


def create_session(user, db):
    token = secrets.token_urlsafe(32)
    expires_at = datetime.now(timezone.utc) + timedelta(days=30)
    db.execute('DELETE FROM user_sessions WHERE expires_at<=now()')
    db.execute('INSERT INTO user_sessions(token_hash,user_id,expires_at) VALUES (%s,%s,%s)',
               (hashlib.sha256(token.encode()).hexdigest(), user['id'], expires_at))
    return {'token': token, 'expires_at': expires_at, 'user': public_user(user)}


def current_user(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(security)]):
    if not credentials or not re.fullmatch(r'[A-Za-z0-9_-]{43}', credentials.credentials):
        raise HTTPException(401, '请先登录')
    token_hash = hashlib.sha256(credentials.credentials.encode()).hexdigest()
    with connect() as db:
        user = db.execute('''SELECT u.id, u.username, u.nickname, u.gender, u.age, u.avatar, u.created_at, s.token_hash
            FROM user_sessions s JOIN users u ON u.id=s.user_id
            WHERE s.token_hash=%s AND s.expires_at>now() AND u.active''', (token_hash,)).fetchone()
    if not user:
        raise HTTPException(401, '登录已过期，请重新登录')
    return user


User = Annotated[dict, Depends(current_user)]

app.include_router(create_journal_router(connect, current_user))
app.include_router(create_couple_router(connect, current_user))
app.include_router(create_travel_router(current_user))
app.include_router(create_research_router(current_user))
app.include_router(create_skill_agent_router(connect, current_user))
app.include_router(create_chatbot_router(connect, current_user))


@app.on_event('startup')
async def start_skill_agent_jobs():
    start_skill_agent_worker()
    global _pomodoro_reminder_task
    if os.environ.get('WECHAT_POMODORO_TEMPLATE_ID', '').strip():
        _pomodoro_reminder_task = asyncio.create_task(_pomodoro_reminder_worker())


@app.on_event('shutdown')
async def stop_skill_agent_jobs():
    global _pomodoro_reminder_task
    if _pomodoro_reminder_task is not None:
        _pomodoro_reminder_task.cancel()
        try:
            await _pomodoro_reminder_task
        except asyncio.CancelledError:
            pass
        _pomodoro_reminder_task = None
    await stop_skill_agent_worker()


def public_user(user):
    avatar = user.get('avatar')
    return {
        key: user[key]
        for key in ('id', 'username', 'nickname', 'gender', 'age', 'created_at')
    } | {
        'avatar_base64': base64.b64encode(bytes(avatar)).decode('ascii')
        if avatar is not None else None
    }


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
                VALUES (%s,%s,%s,%s) RETURNING id,username,nickname,gender,age,created_at''',
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
        session = create_session(user, db)
    return session


@app.post('/auth/wechat/login')
def login_with_wechat(body: WechatCode):
    app_id, openid = wechat_identity(body.code)
    with connect() as db:
        user = db.execute('''SELECT u.* FROM wechat_identities w
            JOIN users u ON u.id=w.user_id
            WHERE w.app_id=%s AND w.openid=%s''', (app_id, openid)).fetchone()
        if not user:
            raise HTTPException(409, '微信尚未绑定账号，请先使用用户名和密码登录并绑定微信')
        if not user['active']:
            raise HTTPException(401, '账号已停用，请使用其他账号')
        session = create_session(user, db)
    return session


@app.post('/auth/wechat/bind')
def bind_wechat(body: WechatCode, user: User):
    app_id, openid = wechat_identity(body.code)
    with connect() as db:
        inserted = db.execute('''INSERT INTO wechat_identities(app_id,openid,user_id)
            VALUES (%s,%s,%s) ON CONFLICT DO NOTHING RETURNING openid''',
            (app_id, openid, user['id'])).fetchone()
        if not inserted:
            current = db.execute('''SELECT openid FROM wechat_identities
                WHERE app_id=%s AND user_id=%s''', (app_id, user['id'])).fetchone()
            owner = db.execute('''SELECT user_id FROM wechat_identities
                WHERE app_id=%s AND openid=%s''', (app_id, openid)).fetchone()
            if current and current['openid'] != openid:
                raise HTTPException(409, '当前账号已绑定其他微信，请先解除原绑定')
            if owner and owner['user_id'] != user['id']:
                raise HTTPException(409, '该微信已绑定其他账号')
    return {'bound': True}


@app.get('/auth/wechat/status')
def wechat_status(user: User):
    app_id = os.environ.get('WECHAT_MINIPROGRAM_APPID', '').strip()
    configured = bool(app_id and os.environ.get('WECHAT_MINIPROGRAM_APPSECRET', '').strip())
    if not configured:
        return {'configured': False, 'bound': False}
    with connect() as db:
        binding = db.execute('''SELECT 1 FROM wechat_identities
            WHERE app_id=%s AND user_id=%s''', (app_id, user['id'])).fetchone()
    return {'configured': True, 'bound': binding is not None}


@app.get('/me')
def me(user: User):
    return public_user(user)


class Profile(Input):
    nickname: str = Field(min_length=1, max_length=32)
    gender: Literal['unset', 'male', 'female']
    age: int | None = Field(default=None, ge=1, le=120, strict=True)

    @field_validator('nickname')
    @classmethod
    def nonempty_nickname(cls, value):
        if not value.strip():
            raise ValueError('昵称不能为空')
        return value.strip()


class AvatarInput(Input):
    photo_base64: str = Field(min_length=4, max_length=11184812)


@app.put('/me')
def save_profile(body: Profile, user: User):
    age = body.age if 'age' in body.model_fields_set else user.get('age')
    with connect() as db:
        updated = db.execute('''UPDATE users SET nickname=%s,gender=%s,age=%s WHERE id=%s
            RETURNING id,username,nickname,gender,age,avatar,created_at''',
            (body.nickname, body.gender, age, user['id'])).fetchone()
    return public_user(updated)


@app.put('/me/avatar')
def save_avatar(body: AvatarInput, user: User):
    _, avatar = prepare_photo(body.photo_base64)
    with connect() as db:
        updated = db.execute('''UPDATE users SET avatar=%s WHERE id=%s
            RETURNING id,username,nickname,gender,age,avatar,created_at''',
            (avatar, user['id'])).fetchone()
    return public_user(updated)


def ai_completion(system_prompt, data):
    api_key = os.environ.get('DEEPSEEK_API_KEY')
    if not api_key:
        raise HTTPException(503, 'AI 服务尚未配置，请联系管理员')
    base_url = os.environ.get('DEEPSEEK_BASE_URL', 'https://api.deepseek.com').rstrip('/')
    endpoint = base_url if base_url.endswith('/chat/completions') else base_url + '/chat/completions'
    payload = {
        'model': os.environ.get('DEEPSEEK_MODEL', 'deepseek-flash'),
        'thinking': {'type': 'disabled'},
        'response_format': {'type': 'json_object'},
        'max_tokens': 1200,
        'messages': [
            {'role': 'system', 'content': system_prompt},
            {'role': 'user', 'content': json.dumps(data, ensure_ascii=False)},
        ],
    }
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, ensure_ascii=False).encode('utf-8'),
        headers={'Authorization': 'Bearer ' + api_key, 'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            result = json.loads(response.read())
        content = result['choices'][0]['message']['content']
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise HTTPException(502, 'DeepSeek 认证失败，请检查服务端配置') from None
        if error.code == 429:
            raise HTTPException(503, 'AI 服务繁忙，请稍后重试') from None
        raise HTTPException(502, 'AI 服务暂不可用，请稍后重试') from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError, IndexError, TypeError):
        raise HTTPException(502, 'AI 服务暂不可用，请稍后重试') from None
    if not isinstance(content, str) or not content.strip():
        raise HTTPException(502, 'AI 服务未返回有效内容')
    try:
        result = json.loads(content)
    except ValueError:
        raise HTTPException(502, 'AI 服务返回格式无效，请稍后重试') from None
    if not isinstance(result, dict):
        raise HTTPException(502, 'AI 服务返回格式无效，请稍后重试')
    for key, value in result.items():
        if isinstance(value, str):
            result[key] = plain_ai_text(value)
        elif isinstance(value, list):
            result[key] = [
                plain_ai_text(item) if isinstance(item, str) else item
                for item in value
            ]
    return result


class AiGeneratedContent(Input):
    summary: str = Field(min_length=1, max_length=1200)
    observations: list[str] = Field(default_factory=list, max_length=4)
    suggestions: list[str] = Field(default_factory=list, max_length=2)


def ai_metric(label, value, unit='', caption=None):
    metric = {'label': label, 'value': str(value)}
    if unit:
        metric['unit'] = unit
    if caption:
        metric['caption'] = caption
    return metric


@app.post('/ai/profile-analysis')
def ai_profile_analysis(user: User):
    with connect() as db:
        weight = db.execute('''SELECT date,grams FROM weight_entries
            WHERE user_id=%s ORDER BY date DESC LIMIT 1''', (user['id'],)).fetchone()
        height = db.execute('''SELECT date,millimeters FROM height_entries
            WHERE user_id=%s ORDER BY date DESC LIMIT 1''', (user['id'],)).fetchone()
    gender = {'male': '男', 'female': '女'}.get(user.get('gender'), '未设置')
    age = user.get('age')
    height_cm = round(height['millimeters'] / 10, 1) if height else None
    weight_kg = round(weight['grams'] / 1000, 1) if weight else None
    bmi = round(weight_kg / (height_cm / 100) ** 2, 1) if age is not None and age >= 18 and height_cm and weight_kg else None
    profile = {
        '年龄': age,
        '性别': gender,
        '最近身高_cm': height_cm,
        '身高记录日期': height['date'].isoformat() if height else None,
        '最近体重_kg': weight_kg,
        '体重记录日期': weight['date'].isoformat() if weight else None,
        'BMI_仅限成年人参考': bmi,
    }
    if age is None and gender == '未设置' and height is None and weight is None:
        raise HTTPException(422, '请先填写年龄、性别或身高体重记录')
    try:
        analysis = AiGeneratedContent.model_validate(
            ai_completion(load_ai_prompt('profile_analysis.md'), profile))
    except ValidationError:
        raise HTTPException(502, 'AI 分析内容格式无效，请稍后重试') from None
    highlights = []
    if age is not None:
        highlights.append(ai_metric('年龄', age, '岁'))
    if gender != '未设置':
        highlights.append(ai_metric('性别', gender))
    if height:
        highlights.append(ai_metric('最近身高', f'{height_cm:.1f}', 'cm',
                                    '记录于 ' + height['date'].isoformat()))
    if weight:
        highlights.append(ai_metric('最近体重', f'{weight_kg:.1f}', 'kg',
                                    '记录于 ' + weight['date'].isoformat()))
    if bmi is not None:
        highlights.append(ai_metric('BMI 粗略值', f'{bmi:.1f}', '', '仅供成年人参考'))
    return {
        'title': '个人分析',
        'subtitle': '基于目前已保存的个人资料',
        'summary': analysis.summary,
        'highlights': highlights,
        'sections': ([{'title': '观察', 'items': [{'value': item} for item in analysis.observations]}]
                     if analysis.observations else []),
        'suggestions': analysis.suggestions,
        'notice': '内容仅供个人记录参考，不构成医疗建议。',
    }


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


class HealthSettings(Input):
    cycle_length: int | None = Field(default=None, ge=1, le=365, strict=True)
    period_length: int | None = Field(default=None, ge=1, le=90, strict=True)
    paused: bool = Field(default=False, strict=True)


class PeriodInput(Input):
    id: int | None = Field(default=None, ge=1, strict=True)
    start_date: date
    end_date: date | None = None
    bleeding_dates: list[date] = Field(min_length=1, max_length=366)

    @model_validator(mode='after')
    def valid_period(self):
        DatedInput.valid_date(self.start_date)
        for day in self.bleeding_dates:
            DatedInput.valid_date(day)
        if len(set(self.bleeding_dates)) != len(self.bleeding_dates):
            raise ValueError('出血日期不能重复')
        self.bleeding_dates.sort()
        if self.bleeding_dates[0] != self.start_date:
            raise ValueError('经期首日必须是最早的实际出血日')
        if self.end_date is not None and self.end_date != self.bleeding_dates[-1]:
            raise ValueError('结束日期必须是最后一个实际出血日')
        if (self.bleeding_dates[-1] - self.start_date).days > 365:
            raise ValueError('一次记录的日期跨度不能超过一年')
        return self


class HealthDay(DatedInput):
    flow: Literal['none', 'light', 'medium', 'heavy'] = 'none'
    pain: int = Field(default=0, ge=0, le=3, strict=True)
    symptoms: list[Literal['腹胀', '头痛', '腰酸', '疲劳', '乳房胀痛', '恶心', '失眠']] = Field(default_factory=list, max_length=7)
    mood: Literal['', '平静', '开心', '低落', '烦躁', '焦虑'] = ''
    spotting: bool = Field(default=False, strict=True)
    notes: str = Field(default='', max_length=2000)

    @field_validator('symptoms')
    @classmethod
    def unique_symptoms(cls, values):
        if len(values) != len(set(values)):
            raise ValueError('症状不能重复')
        return values


def lock_health_owner(db, user):
    # Serialize overlapping period edits and profile changes for this account.
    row = db.execute('SELECT gender FROM users WHERE id=%s FOR UPDATE', (user['id'],)).fetchone()
    if row['gender'] != 'female':
        raise HTTPException(403, '请先在个人资料中选择女生')


@app.get('/female-health')
def female_health(user: User):
    with connect() as db:
        lock_health_owner(db, user)
        settings = db.execute('SELECT cycle_length,period_length,paused FROM female_health_settings WHERE user_id=%s',
                              (user['id'],)).fetchone()
        periods = db.execute('''SELECT id,start_date,end_date,bleeding_dates FROM menstrual_periods
            WHERE user_id=%s ORDER BY start_date''', (user['id'],)).fetchall()
        days = db.execute('''SELECT date,flow,pain,symptoms,mood,spotting,notes FROM female_health_days
            WHERE user_id=%s ORDER BY date''', (user['id'],)).fetchall()
    return {'settings': settings or HealthSettings().model_dump(), 'periods': periods, 'days': days}


@app.put('/female-health/settings')
def save_health_settings(body: HealthSettings, user: User):
    with connect() as db:
        lock_health_owner(db, user)
        db.execute('''INSERT INTO female_health_settings(user_id,cycle_length,period_length,paused)
            VALUES (%s,%s,%s,%s) ON CONFLICT(user_id) DO UPDATE SET
            cycle_length=EXCLUDED.cycle_length,period_length=EXCLUDED.period_length,paused=EXCLUDED.paused''',
            (user['id'], body.cycle_length, body.period_length, body.paused))
    return {'ok': True}


@app.put('/female-health/periods')
def save_period(body: PeriodInput, user: User):
    dates = [day.isoformat() for day in body.bleeding_dates]
    with connect() as db:
        lock_health_owner(db, user)
        existing = db.execute('''SELECT id,start_date,end_date,bleeding_dates FROM menstrual_periods
            WHERE user_id=%s ORDER BY start_date''', (user['id'],)).fetchall()
        if body.id is not None and not any(row['id'] == body.id for row in existing):
            raise HTTPException(404, '经期记录不存在')
        for row in existing:
            if row['id'] == body.id:
                continue
            # An identical retry is safe even when the first response was lost.
            if body.id is None and row['start_date'] == body.start_date and row['end_date'] == body.end_date and row['bleeding_dates'] == dates:
                return {'id': row['id']}
            old_end = row['end_date'] or date.max
            new_end = body.end_date or date.max
            if body.start_date <= old_end and row['start_date'] <= new_end:
                raise HTTPException(409, '经期日期重叠，请先结束进行中的经期或修改日期')
        if body.id is None:
            result = db.execute('''INSERT INTO menstrual_periods(user_id,start_date,end_date,bleeding_dates)
                VALUES (%s,%s,%s,%s) RETURNING id''',
                (user['id'], body.start_date, body.end_date, Jsonb(dates))).fetchone()
        else:
            result = db.execute('''UPDATE menstrual_periods SET start_date=%s,end_date=%s,bleeding_dates=%s
                WHERE user_id=%s AND id=%s RETURNING id''',
                (body.start_date, body.end_date, Jsonb(dates), user['id'], body.id)).fetchone()
    return result


@app.delete('/female-health/periods')
def delete_period(user: User, id: Annotated[int, Query(ge=1)]):
    with connect() as db:
        lock_health_owner(db, user)
        db.execute('DELETE FROM menstrual_periods WHERE user_id=%s AND id=%s', (user['id'], id))
    return {'ok': True}


@app.put('/female-health/days')
def save_health_day(body: HealthDay, user: User):
    with connect() as db:
        lock_health_owner(db, user)
        upsert(db, 'female_health_days', user['id'], body.model_dump(), ['date'])
    return {'ok': True}


@app.delete('/female-health/days')
def delete_health_day(user: User, date: date):
    with connect() as db:
        lock_health_owner(db, user)
        db.execute('DELETE FROM female_health_days WHERE user_id=%s AND date=%s', (user['id'], date))
    return {'ok': True}


@app.delete('/female-health')
def clear_health(user: User, reset_settings: bool = False):
    with connect() as db:
        lock_health_owner(db, user)
        db.execute('DELETE FROM menstrual_periods WHERE user_id=%s', (user['id'],))
        db.execute('DELETE FROM female_health_days WHERE user_id=%s', (user['id'],))
        if reset_settings:
            db.execute('DELETE FROM female_health_settings WHERE user_id=%s', (user['id'],))
    return {'ok': True}


class Weight(DatedInput):
    grams: int = Field(ge=20000, le=300000, strict=True)


class Height(DatedInput):
    millimeters: int = Field(ge=800, le=2500, strict=True)


class MealItemInput(Input):
    name: str = Field(min_length=1, max_length=80)
    expense_cents: int = Field(ge=0, le=10000000000, strict=True)

    @field_validator('name')
    @classmethod
    def nonempty_name(cls, value):
        if not value.strip():
            raise ValueError('食物名称不能为空')
        return value.strip()


class Meal(DatedInput):
    meal_type: Literal['早餐', '午餐', '晚餐']
    foods: str = Field(min_length=1, max_length=2000)
    expense_cents: int = Field(ge=0, le=10000000000, strict=True)
    items: list[MealItemInput] | None = Field(default=None, max_length=20)

    @field_validator('foods')
    @classmethod
    def nonempty_foods(cls, value):
        if not value.strip():
            raise ValueError('餐食内容不能为空')
        return value.strip()

    @model_validator(mode='after')
    def meal_item_total(self):
        if self.items:
            total = sum(item.expense_cents for item in self.items)
            if total > 10000000000 or total != self.expense_cents:
                raise ValueError('餐食总金额与明细金额不一致')
        return self


class OtherExpenseInput(DatedInput):
    category: str = Field(min_length=1, max_length=80)
    expense_cents: int = Field(ge=0, le=10000000000, strict=True)

    @field_validator('category')
    @classmethod
    def nonempty_category(cls, value):
        if not value.strip():
            raise ValueError('消费类别不能为空')
        return value.strip()


class IncomeInput(DatedInput):
    category: str = Field(min_length=1, max_length=80)
    income_cents: int = Field(gt=0, le=10000000000, strict=True)
    notes: str = Field(default='', max_length=1000)

    @field_validator('category')
    @classmethod
    def income_category(cls, value):
        if not value.strip():
            raise ValueError('收入分类不能为空')
        return value.strip()

    @field_validator('notes')
    @classmethod
    def income_notes(cls, value):
        return value.strip()


class IncomeCreate(IncomeInput):
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')


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


class BodySettingsInput(Input):
    goal_weight_grams: int | None = Field(
        ..., ge=20000, le=300000, strict=True)


@app.get('/body/settings')
def body_settings(user: User):
    with connect() as db:
        settings = db.execute(
            'SELECT goal_weight_grams FROM body_settings WHERE user_id=%s',
            (user['id'],)).fetchone()
    return settings or {'goal_weight_grams': None}


@app.put('/body/settings')
def save_body_settings(body: BodySettingsInput, user: User):
    with connect() as db:
        db.execute('''INSERT INTO body_settings(user_id,goal_weight_grams) VALUES (%s,%s)
            ON CONFLICT(user_id) DO UPDATE SET goal_weight_grams=EXCLUDED.goal_weight_grams''',
            (user['id'], body.goal_weight_grams))
    return {'ok': True}


@app.get('/meals')
def meals(user: User, start: date, end: date):
    if start > end:
        raise HTTPException(422, '日期范围不正确')
    with connect() as db:
        return db.execute('''SELECT date,meal_type,foods,expense_cents,items FROM meal_entries
            WHERE user_id=%s AND date BETWEEN %s AND %s ORDER BY date,meal_type''', (user['id'], start, end)).fetchall()


@app.put('/meals')
def save_meal(body: Meal, user: User):
    with connect() as db:
        row = body.model_dump(exclude={'items'}, exclude_none=True)
        row['items'] = [item.model_dump() for item in body.items or []]
        upsert(db, 'meal_entries', user['id'], row, ['date', 'meal_type'])
    return {'ok': True}


@app.delete('/meals')
def delete_meal(user: User, date: date, meal_type: Literal['早餐', '午餐', '晚餐']):
    with connect() as db:
        db.execute('DELETE FROM meal_entries WHERE user_id=%s AND date=%s AND meal_type=%s', (user['id'], date, meal_type))
    return {'ok': True}


@app.get('/other-expenses')
def other_expenses(user: User, start: date, end: date):
    if start > end:
        raise HTTPException(422, '日期范围不正确')
    with connect() as db:
        return db.execute('''SELECT id,date,category,expense_cents FROM other_expense_entries
            WHERE user_id=%s AND date BETWEEN %s AND %s ORDER BY date,id''',
            (user['id'], start, end)).fetchall()


@app.post('/other-expenses', status_code=201)
def create_other_expense(body: OtherExpenseInput, user: User):
    with connect() as db:
        return db.execute('''INSERT INTO other_expense_entries(user_id,date,category,expense_cents)
            VALUES (%s,%s,%s,%s) RETURNING id,date,category,expense_cents''',
            (user['id'], body.date, body.category, body.expense_cents)).fetchone()


@app.put('/other-expenses/{expense_id}')
def update_other_expense(expense_id: int, body: OtherExpenseInput, user: User):
    with connect() as db:
        row = db.execute('''UPDATE other_expense_entries
            SET date=%s,category=%s,expense_cents=%s
            WHERE user_id=%s AND id=%s
            RETURNING id,date,category,expense_cents''',
            (body.date, body.category, body.expense_cents, user['id'], expense_id)).fetchone()
        if not row:
            raise HTTPException(404, '其他消费记录不存在')
        return row


@app.delete('/other-expenses/{expense_id}')
def delete_other_expense(expense_id: int, user: User):
    with connect() as db:
        removed = db.execute('''DELETE FROM other_expense_entries
            WHERE user_id=%s AND id=%s RETURNING id''', (user['id'], expense_id)).fetchone()
        if not removed:
            raise HTTPException(404, '其他消费记录不存在')
    return {'ok': True}


@app.get('/incomes')
def incomes(user: User, start: date, end: date):
    if start > end or start < date(2000, 1, 1) or (end - start).days > 366:
        raise HTTPException(422, '收入查询日期范围不正确，最多查询一年')
    with connect() as db:
        return db.execute('''SELECT id,date,category,income_cents,notes FROM income_entries
            WHERE user_id=%s AND date BETWEEN %s AND %s ORDER BY date DESC,id DESC''',
            (user['id'], start, end)).fetchall()


@app.post('/incomes', status_code=201)
def create_income(body: IncomeCreate, user: User):
    # 金额始终按整数分保存；原始请求摘要保留到编辑之后，防止网络重试重复记账。
    payload = body.model_dump(mode='json', exclude={'client_request_id'})
    fingerprint = hashlib.sha256(json.dumps(
        payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    with connect() as db:
        row = db.execute('''INSERT INTO income_entries
            (user_id,date,category,income_cents,notes,client_request_id,request_hash)
            VALUES (%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT(user_id,client_request_id) DO NOTHING
            RETURNING id,date,category,income_cents,notes''',
            (user['id'], body.date, body.category, body.income_cents,
             body.notes, body.client_request_id, fingerprint)).fetchone()
        if row is None:
            row = db.execute('''SELECT id,date,category,income_cents,notes,request_hash
                FROM income_entries WHERE user_id=%s AND client_request_id=%s''',
                (user['id'], body.client_request_id)).fetchone()
            if row is None or row.pop('request_hash') != fingerprint:
                raise HTTPException(409, '该收入请求已使用，请刷新后确认原记录')
        return row


@app.put('/incomes/{income_id}')
def update_income(income_id: int, body: IncomeInput, user: User):
    with connect() as db:
        row = db.execute('''UPDATE income_entries SET date=%s,category=%s,income_cents=%s,notes=%s
            WHERE user_id=%s AND id=%s RETURNING id,date,category,income_cents,notes''',
            (body.date, body.category, body.income_cents, body.notes, user['id'], income_id)).fetchone()
        if row is None:
            raise HTTPException(404, '收入记录不存在')
        return row


@app.delete('/incomes/{income_id}')
def delete_income(income_id: int, user: User):
    with connect() as db:
        # 修改和删除均限定当前账号，不能通过猜测记录编号操作他人的收入。
        row = db.execute('DELETE FROM income_entries WHERE user_id=%s AND id=%s RETURNING id',
                         (user['id'], income_id)).fetchone()
        if row is None:
            raise HTTPException(404, '收入记录不存在')
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


class WorkoutActionInput(Input):
    name: str = Field(min_length=1, max_length=60)
    sets: int = Field(ge=1, le=100, strict=True)
    reps: int = Field(ge=1, le=1000, strict=True)

    @field_validator('name')
    @classmethod
    def nonempty_name(cls, value):
        if not value.strip():
            raise ValueError('动作名称不能为空')
        return value.strip()


class WorkoutLogInput(DatedInput):
    muscles: list[LogMuscle] = Field(min_length=1, max_length=100)
    actions: list[WorkoutActionInput] = Field(default_factory=list, max_length=20)


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
        return db.execute('''SELECT date,muscles,actions FROM workout_logs WHERE user_id=%s
            AND date BETWEEN %s AND %s ORDER BY date''', (user['id'], start, end)).fetchall()


@app.post('/workout/logs', status_code=201)
def check_in(body: WorkoutLogInput, user: User):
    today = datetime.now(ZoneInfo('Asia/Shanghai')).date()
    if body.date < date(2000, 1, 1) or body.date > today:
        raise HTTPException(422, '打卡日期范围无效')
    try:
        with connect() as db:
            db.execute('SELECT id FROM users WHERE id=%s FOR UPDATE', (user['id'],))
            plan = db.execute('SELECT is_rest FROM workout_plans WHERE user_id=%s AND weekday=%s',
                              (user['id'], body.date.isoweekday())).fetchone()
            if body.date == today and plan and plan['is_rest']:
                raise HTTPException(409, '今天是休息日，不能打卡')
            names = [m.name for m in body.muscles]
            owned = db.execute('SELECT name,color_value FROM workout_muscles WHERE user_id=%s AND name=ANY(%s)',
                               (user['id'], names)).fetchall()
            if len(set(names)) != len(names) or len(owned) != len(names):
                raise HTTPException(422, '训练部位不存在或重复')
            colors = {r['name']: r['color_value'] for r in owned}
            muscles = [{'name': name, 'color': colors[name]} for name in names]
            actions = [action.model_dump() for action in body.actions]
            db.execute('''INSERT INTO workout_logs(user_id,date,muscles,actions)
                VALUES (%s,%s,%s,%s)''',
                       (user['id'], body.date, Jsonb(muscles), Jsonb(actions)))
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, '这一天已经打卡')
    return {'ok': True}


@app.delete('/workout/logs')
def undo_check_in(user: User, date: date):
    with connect() as db:
        db.execute('DELETE FROM workout_logs WHERE user_id=%s AND date=%s', (user['id'], date))
    return {'ok': True}


class PomodoroTaskInput(Input):
    title: str = Field(min_length=1, max_length=120)

    @field_validator('title')
    @classmethod
    def nonempty_title(cls, value):
        if not value.strip():
            raise ValueError('专注事项不能为空')
        return value.strip()


class PomodoroSettingsInput(Input):
    focus_minutes: int = Field(ge=1, le=120, strict=True)
    short_break_minutes: int = Field(ge=1, le=60, strict=True)
    long_break_minutes: int = Field(ge=1, le=120, strict=True)
    rounds_per_long_break: int = Field(ge=2, le=12, strict=True)


class PomodoroSessionInput(Input):
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')
    task_id: int | None = Field(default=None, ge=1, strict=True)
    task_title: str = Field(min_length=1, max_length=120)
    duration_minutes: int = Field(ge=1, le=120, strict=True)
    started_at: datetime
    completed_at: datetime

    @field_validator('task_title')
    @classmethod
    def nonempty_task_title(cls, value):
        if not value.strip():
            raise ValueError('专注事项不能为空')
        return value.strip()

    @model_validator(mode='after')
    def valid_times(self):
        now = datetime.now(timezone.utc)
        for value in (self.started_at, self.completed_at):
            if value.tzinfo is None or value.utcoffset() is None or value > now + timedelta(minutes=1):
                raise ValueError('专注时间格式不正确')
        if self.completed_at <= self.started_at:
            raise ValueError('结束时间必须晚于开始时间')
        return self


class PomodoroReminderInput(Input):
    client_request_id: str = Field(pattern=r'^[a-f0-9]{32}$')
    trigger_at: datetime
    phase: Literal['focus', 'shortBreak', 'longBreak']
    task_title: str = Field(default='', max_length=120)

    @model_validator(mode='after')
    def valid_trigger(self):
        now = datetime.now(timezone.utc)
        if self.trigger_at.tzinfo is None or self.trigger_at.utcoffset() is None:
            raise ValueError('提醒时间必须包含时区')
        trigger = self.trigger_at.astimezone(timezone.utc)
        if trigger < now - timedelta(minutes=1) or trigger > now + timedelta(hours=3):
            raise ValueError('提醒时间应在当前至 3 小时内')
        return self


@app.post('/pomodoro/reminders')
def schedule_pomodoro_reminder(body: PomodoroReminderInput, user: User):
    app_id = os.environ.get('WECHAT_MINIPROGRAM_APPID', '').strip()
    template_id = os.environ.get('WECHAT_POMODORO_TEMPLATE_ID', '').strip()
    if not app_id or not template_id or not os.environ.get('WECHAT_MINIPROGRAM_APPSECRET', '').strip():
        raise HTTPException(503, '微信番茄钟订阅提醒尚未配置')
    with connect() as db:
        identity = db.execute('''SELECT openid FROM wechat_identities
            WHERE app_id=%s AND user_id=%s''', (app_id, user['id'])).fetchone()
        if not identity:
            raise HTTPException(409, '请先绑定微信账号，再开启微信提醒')
        trigger_at = body.trigger_at.astimezone(timezone.utc)
        inserted = db.execute('''INSERT INTO pomodoro_reminders
            (user_id,app_id,request_id,template_id,phase,task_title,trigger_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT(user_id,request_id) DO NOTHING RETURNING id,status''',
            (user['id'], app_id, body.client_request_id, template_id, body.phase,
             body.task_title.strip(), trigger_at)).fetchone()
        if inserted:
            return {'scheduled': True, 'status': inserted['status']}
        existing = db.execute('''SELECT phase,task_title,trigger_at,status FROM pomodoro_reminders
            WHERE user_id=%s AND request_id=%s''',
            (user['id'], body.client_request_id)).fetchone()
        if not existing or existing['phase'] != body.phase or existing['task_title'] != body.task_title.strip() or existing['trigger_at'] != trigger_at:
            raise HTTPException(409, '该提醒请求已使用，请重新开始计时')
    return {'scheduled': True, 'status': existing['status']}


@app.delete('/pomodoro/reminders')
def cancel_pomodoro_reminder(user: User, request_id: Annotated[str, Query(pattern=r'^[a-f0-9]{32}$')]):
    with connect() as db:
        db.execute('''UPDATE pomodoro_reminders SET status='cancelled'
            WHERE user_id=%s AND request_id=%s AND status='pending' ''',
            (user['id'], request_id))
    return {'cancelled': True}


@app.get('/pomodoro/settings')
def pomodoro_settings(user: User):
    with connect() as db:
        db.execute('INSERT INTO pomodoro_settings(user_id) VALUES (%s) ON CONFLICT DO NOTHING',
                   (user['id'],))
        return db.execute('''SELECT focus_minutes,short_break_minutes,long_break_minutes,rounds_per_long_break
            FROM pomodoro_settings WHERE user_id=%s''', (user['id'],)).fetchone()


@app.put('/pomodoro/settings')
def save_pomodoro_settings(body: PomodoroSettingsInput, user: User):
    with connect() as db:
        db.execute('''INSERT INTO pomodoro_settings
            (user_id,focus_minutes,short_break_minutes,long_break_minutes,rounds_per_long_break)
            VALUES (%s,%s,%s,%s,%s) ON CONFLICT(user_id) DO UPDATE SET
            focus_minutes=EXCLUDED.focus_minutes,short_break_minutes=EXCLUDED.short_break_minutes,
            long_break_minutes=EXCLUDED.long_break_minutes,
            rounds_per_long_break=EXCLUDED.rounds_per_long_break''',
            (user['id'], body.focus_minutes, body.short_break_minutes,
             body.long_break_minutes, body.rounds_per_long_break))
    return {'ok': True}


@app.get('/pomodoro/tasks')
def pomodoro_tasks(user: User):
    with connect() as db:
        return db.execute('''SELECT id,title,created_at FROM pomodoro_tasks
            WHERE user_id=%s ORDER BY created_at DESC,id DESC''', (user['id'],)).fetchall()


@app.post('/pomodoro/tasks', status_code=201)
def add_pomodoro_task(body: PomodoroTaskInput, user: User):
    try:
        with connect() as db:
            existing = db.execute('''SELECT id,title,created_at FROM pomodoro_tasks
                WHERE user_id=%s AND lower(title)=lower(%s)''', (user['id'], body.title)).fetchone()
            if existing:
                return existing
            return db.execute('''INSERT INTO pomodoro_tasks(user_id,title)
                VALUES (%s,%s) RETURNING id,title,created_at''',
                (user['id'], body.title)).fetchone()
    except psycopg.errors.UniqueViolation:
        with connect() as db:
            return db.execute('''SELECT id,title,created_at FROM pomodoro_tasks
                WHERE user_id=%s AND lower(title)=lower(%s)''', (user['id'], body.title)).fetchone()


@app.delete('/pomodoro/tasks')
def delete_pomodoro_task(user: User, id: Annotated[int, Query(ge=1)]):
    with connect() as db:
        removed = db.execute('DELETE FROM pomodoro_tasks WHERE user_id=%s AND id=%s',
                             (user['id'], id)).rowcount
        if not removed:
            raise HTTPException(404, '专注事项不存在')
    return {'ok': True}


@app.get('/pomodoro/sessions')
def pomodoro_sessions(user: User, start: date, end: date):
    if start > end or start < date(2000, 1, 1) or end > datetime.now(ZoneInfo('Asia/Shanghai')).date():
        raise HTTPException(422, '日期范围不正确')
    with connect() as db:
        return db.execute('''SELECT client_request_id,task_title,duration_minutes,started_at,completed_at
            FROM pomodoro_sessions WHERE user_id=%s
            AND (started_at AT TIME ZONE 'Asia/Shanghai')::date BETWEEN %s AND %s
            ORDER BY started_at DESC,id DESC''', (user['id'], start, end)).fetchall()


@app.post('/ai/daily-summary')
def ai_daily_summary(body: DatedInput, user: User):
    day = body.date
    with connect() as db:
        meals = db.execute('''SELECT meal_type,foods,expense_cents FROM meal_entries
            WHERE user_id=%s AND date=%s ORDER BY meal_type''', (user['id'], day)).fetchall()
        weight = db.execute('SELECT grams FROM weight_entries WHERE user_id=%s AND date=%s',
                            (user['id'], day)).fetchone()
        height = db.execute('SELECT millimeters FROM height_entries WHERE user_id=%s AND date=%s',
                            (user['id'], day)).fetchone()
        workout = db.execute('SELECT muscles FROM workout_logs WHERE user_id=%s AND date=%s',
                             (user['id'], day)).fetchone()
        focus = db.execute('''SELECT task_title,duration_minutes FROM pomodoro_sessions
            WHERE user_id=%s AND (started_at AT TIME ZONE 'Asia/Shanghai')::date=%s
            ORDER BY started_at''', (user['id'], day)).fetchall()
        journal = db.execute('''SELECT kind,title,left(content,2000) AS content,
            length(content)>2000 AS content_truncated,is_todo,completed FROM journal_entries
            WHERE user_id=%s AND entry_date=%s ORDER BY created_at LIMIT 21''',
            (user['id'], day)).fetchall()
    journal_truncated = len(journal) > 20
    journal = journal[:20]
    journal_content_truncated = any(entry['content_truncated'] for entry in journal)
    workout_muscles = [muscle['name'] for muscle in workout['muscles']] if workout else []
    expense_cents = sum(meal['expense_cents'] for meal in meals)
    data = {
        '日期': day.isoformat(),
        '饮食记录': [
            {'餐次': meal['meal_type'], '食物': meal['foods'],
             '消费元': f"{meal['expense_cents'] / 100:.2f}"}
            for meal in meals
        ],
        '餐饮消费合计元': f'{expense_cents / 100:.2f}',
        '身体记录': {
            '体重_kg': round(weight['grams'] / 1000, 1) if weight else None,
            '身高_cm': round(height['millimeters'] / 10, 1) if height else None,
        },
        '健身打卡部位': workout_muscles,
        '专注记录': {
            '完成次数': len(focus),
            '专注分钟': sum(session['duration_minutes'] for session in focus),
            '事项': [{'名称': session['task_title'], '分钟': session['duration_minutes']}
                     for session in focus],
        },
        '日记和备忘': [
            {'类型': '日记' if entry['kind'] == 'diary' else '备忘',
             '标题': entry['title'], '内容': entry['content'],
             '内容有截断': entry['content_truncated'],
             '待办': entry['is_todo'], '已完成': entry['completed']}
            for entry in journal
        ],
        '日记备忘有未包含记录': journal_truncated or journal_content_truncated,
    }
    if not meals and not weight and not height and not workout and not focus and not journal:
        return {
            'title': '今日总结',
            'subtitle': f'{day.month}月{day.day}日',
            'summary': '当天还没有可总结的记录。',
            'highlights': [],
            'sections': [],
            'suggestions': ['可以先记下一件今天做过的事，之后就能得到更贴近当天的回顾。'],
            'notice': None,
            'date': day.isoformat(),
            'meal_expense_total_cents': 0,
        }
    try:
        generated = AiGeneratedContent.model_validate(
            ai_completion(load_ai_prompt('daily_summary.md'), data))
    except ValidationError:
        raise HTTPException(502, 'AI 总结内容格式无效，请稍后重试') from None

    highlights = []
    sections = []
    if meals:
        highlights.append(ai_metric('餐饮消费', f'¥{expense_cents / 100:.2f}',
                                    caption=f'{len(meals)} 餐记录'))
        sections.append({
            'title': '饮食与消费',
            'items': [
                {'label': meal['meal_type'], 'value': meal['foods'],
                 'detail': f"¥{meal['expense_cents'] / 100:.2f}"}
                for meal in meals
            ],
        })
    body_items = []
    if weight:
        value = f"{weight['grams'] / 1000:.1f} kg"
        highlights.append(ai_metric('体重记录', f"{weight['grams'] / 1000:.1f}", 'kg'))
        body_items.append({'label': '体重', 'value': value})
    if height:
        value = f"{height['millimeters'] / 10:.1f} cm"
        highlights.append(ai_metric('身高记录', f"{height['millimeters'] / 10:.1f}", 'cm'))
        body_items.append({'label': '身高', 'value': value})
    if body_items:
        sections.append({'title': '身体记录', 'items': body_items})
    activity_items = []
    if workout_muscles:
        muscles = '、'.join(workout_muscles)
        highlights.append(ai_metric('健身打卡', muscles))
        activity_items.append({'label': '训练部位', 'value': muscles})
    if focus:
        focus_minutes = sum(session['duration_minutes'] for session in focus)
        highlights.append(ai_metric('专注时长', focus_minutes, '分钟',
                                    f'{len(focus)} 次番茄钟'))
        task_names = '、'.join(dict.fromkeys(session['task_title'] for session in focus[:5]))
        activity_items.append({
            'label': '番茄钟', 'value': f'{len(focus)} 次 · {focus_minutes} 分钟',
            'detail': task_names or None,
        })
    if activity_items:
        sections.append({'title': '健身与专注', 'items': activity_items})
    if journal:
        journal_items = []
        for entry in journal:
            kind = '日记' if entry['kind'] == 'diary' else '备忘'
            if entry['is_todo']:
                kind = '已完成' if entry['completed'] else '待办'
            journal_items.append({
                'label': entry['title'] or kind,
                'value': entry['content'] or '无正文',
                'detail': '内容有截取' if entry['content_truncated'] else kind,
            })
        sections.append({'title': '日记与备忘', 'items': journal_items})
    return {
        'title': '今日总结',
        'subtitle': f'{day.month}月{day.day}日',
        'summary': generated.summary,
        'highlights': highlights,
        'sections': sections,
        'suggestions': generated.suggestions,
        'notice': ('部分日记或备忘内容未完整纳入总结。'
                   if journal_truncated or journal_content_truncated else None),
        'date': day.isoformat(),
        'meal_expense_total_cents': expense_cents,
    }


@app.post('/pomodoro/sessions', status_code=201)
def save_pomodoro_session(body: PomodoroSessionInput, user: User):
    try:
        with connect() as db:
            existing = db.execute('''SELECT client_request_id FROM pomodoro_sessions
                WHERE user_id=%s AND client_request_id=%s''',
                (user['id'], body.client_request_id)).fetchone()
            if existing:
                return {'ok': True}
            if body.task_id is not None and not db.execute(
                    'SELECT 1 FROM pomodoro_tasks WHERE user_id=%s AND id=%s',
                    (user['id'], body.task_id)).fetchone():
                raise HTTPException(422, '专注事项不存在')
            db.execute('''INSERT INTO pomodoro_sessions
                (user_id,task_id,client_request_id,task_title,duration_minutes,started_at,completed_at)
                VALUES (%s,%s,%s,%s,%s,%s,%s)''',
                (user['id'], body.task_id, body.client_request_id, body.task_title,
                 body.duration_minutes, body.started_at, body.completed_at))
    except psycopg.errors.UniqueViolation:
        with connect() as db:
            if not db.execute('''SELECT 1 FROM pomodoro_sessions
                WHERE user_id=%s AND client_request_id=%s''',
                (user['id'], body.client_request_id)).fetchone():
                raise
    return {'ok': True}


# The whitelist is shared by import validation and SQL construction.
IMPORT_TABLES = {
    'weight_entries': (['date', 'grams'], ['date']),
    'height_entries': (['date', 'millimeters'], ['date']),
    'meal_entries': (['date', 'meal_type', 'foods', 'expense_cents', 'items'], ['date', 'meal_type']),
    'workout_muscles': (['name', 'color_value', 'built_in'], ['name']),
    'workout_plans': (['weekday', 'muscles', 'is_rest'], ['weekday']),
    'workout_logs': (['date', 'muscles', 'actions'], ['date']),
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
    for field in ('muscles', 'actions'):
        if field in row and isinstance(row[field], str):
            row[field] = json.loads(row[field])
    if table == 'weight_entries':
        row = Weight.model_validate(row).model_dump()
    elif table == 'height_entries':
        row = Height.model_validate(row).model_dump()
    elif table == 'meal_entries':
        row.setdefault('items', [])
        row = Meal.model_validate(row).model_dump()
    elif table == 'workout_logs':
        row.setdefault('actions', [])
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
