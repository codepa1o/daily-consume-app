"""微信身份和提醒接口检查；微信调用使用模拟，数据库使用隔离 schema。"""
import os
import secrets
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import psycopg
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from psycopg.conninfo import make_conninfo

import app as api


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), '需要隔离的 TEST_DATABASE_URL')
class WechatApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_dsn = os.environ['TEST_DATABASE_URL']
        cls.schema = 'wechat_test_' + secrets.token_hex(6)
        cls.original_dsn = api.DSN
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'CREATE SCHEMA {cls.schema}')
        cls.addClassCleanup(cls.cleanup)
        api.DSN = make_conninfo(cls.base_dsn, options=f'-csearch_path={cls.schema}')
        config = Config(str(Path(__file__).with_name('alembic.ini')))
        config.attributes['database_url'] = api.DSN
        command.upgrade(config, 'head')
        cls.client = TestClient(api.app)

    @classmethod
    def cleanup(cls):
        api.DSN = cls.original_dsn
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'DROP SCHEMA {cls.schema} CASCADE')

    def setUp(self):
        self.config = patch.dict(os.environ, {
            'WECHAT_MINIPROGRAM_APPID': 'test-app',
            'WECHAT_MINIPROGRAM_APPSECRET': 'mock-only',
            'WECHAT_POMODORO_TEMPLATE_ID': 'test-template',
        })
        self.config.start()
        self.addCleanup(self.config.stop)
        self.identities = patch.object(api, 'wechat_identity', side_effect=lambda code: ('test-app', code))
        self.identities.start()
        self.addCleanup(self.identities.stop)
        self.users = []
        for _ in range(2):
            credentials = {'username': 'wechat_' + secrets.token_hex(6), 'password': secrets.token_urlsafe(18)}
            self.assertEqual(self.client.post('/auth/register', json=credentials).status_code, 201)
            session = self.client.post('/auth/login', json=credentials).json()
            self.users.append((session['user']['id'], {'Authorization': 'Bearer ' + session['token']}))
        (self.user_a, self.a), (self.user_b, self.b) = self.users
        self.openid = secrets.token_hex(12)

    def bind(self, headers, code):
        return self.client.post('/auth/wechat/bind', headers=headers, json={'code': code})

    def reminder(self, **changes):
        return {'client_request_id': secrets.token_hex(16),
                'trigger_at': (datetime.now(timezone.utc) + timedelta(minutes=25)).isoformat(),
                'phase': 'focus', 'task_title': '阅读'} | changes

    def test_login_binding_is_account_scoped_and_retryable(self):
        self.assertEqual(self.client.post('/auth/wechat/login', json={'code': self.openid}).status_code, 409)
        self.assertEqual(self.client.get('/auth/wechat/status').status_code, 401)
        self.assertEqual(self.bind(self.a, self.openid).status_code, 200)
        self.assertEqual(self.bind(self.a, self.openid).status_code, 200)
        self.assertEqual(self.bind(self.b, self.openid).status_code, 409)
        self.assertEqual(self.bind(self.a, self.openid + 'other').status_code, 409)
        self.assertTrue(self.client.get('/auth/wechat/status', headers=self.a).json()['bound'])
        self.assertFalse(self.client.get('/auth/wechat/status', headers=self.b).json()['bound'])
        login = self.client.post('/auth/wechat/login', json={'code': self.openid})
        self.assertEqual(login.status_code, 200)
        self.assertEqual(login.json()['user']['id'], self.user_a)
        self.assertNotIn('openid', login.text)

    def test_reminders_require_binding_and_preserve_idempotence(self):
        body = self.reminder()
        self.assertEqual(self.client.post('/pomodoro/reminders', json=body).status_code, 401)
        self.assertEqual(self.client.post('/pomodoro/reminders', headers=self.a, json=body).status_code, 409)
        self.assertEqual(self.bind(self.a, self.openid).status_code, 200)
        for _ in range(2):
            result = self.client.post('/pomodoro/reminders', headers=self.a, json=body)
            self.assertEqual(result.status_code, 200)
            self.assertEqual(result.json()['status'], 'pending')
        self.assertEqual(self.client.post('/pomodoro/reminders', headers=self.a,
            json=body | {'task_title': '不同事项'}).status_code, 409)
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT count(*) AS n FROM pomodoro_reminders WHERE user_id=%s', (self.user_a,)).fetchone()['n'], 1)
        self.client.delete('/pomodoro/reminders', headers=self.b, params={'request_id': body['client_request_id']})
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT status FROM pomodoro_reminders WHERE user_id=%s', (self.user_a,)).fetchone()['status'], 'pending')
        self.client.delete('/pomodoro/reminders', headers=self.a, params={'request_id': body['client_request_id']})
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT status FROM pomodoro_reminders WHERE user_id=%s', (self.user_a,)).fetchone()['status'], 'cancelled')

    def test_invalid_deadlines_and_missing_configuration_are_rejected(self):
        for value in (datetime.now().isoformat(),
                      (datetime.now(timezone.utc) + timedelta(hours=4)).isoformat(),
                      (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()):
            result = self.client.post('/pomodoro/reminders', headers=self.a, json=self.reminder(trigger_at=value))
            self.assertEqual(result.status_code, 422)
        with patch.dict(os.environ, {'WECHAT_MINIPROGRAM_APPSECRET': ''}):
            self.assertEqual(self.client.post('/pomodoro/reminders', headers=self.a, json=self.reminder()).status_code, 503)
            self.assertEqual(self.client.get('/auth/wechat/status', headers=self.a).json(), {'configured': False, 'bound': False})


if __name__ == '__main__':
    unittest.main()
