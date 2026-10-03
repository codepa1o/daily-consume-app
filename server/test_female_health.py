"""HTTP and real PostgreSQL checks in an isolated schema; no database mocks.

Run: TEST_DATABASE_URL=<disposable PostgreSQL DSN> python -m unittest discover -s server -p test_female_health.py -v
"""
import os
import secrets
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psycopg
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from psycopg.conninfo import make_conninfo

import app as api


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), 'TEST_DATABASE_URL must name a test database')
class HealthApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_dsn = os.environ['TEST_DATABASE_URL']
        cls.schema = 'female_health_test_' + secrets.token_hex(6)
        cls.original_dsn = api.DSN
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'CREATE SCHEMA {cls.schema}')
        api.DSN = make_conninfo(cls.base_dsn, options=f'-csearch_path={cls.schema}')
        config = Config(str(Path(__file__).with_name('alembic.ini')))
        config.attributes['database_url'] = api.DSN
        command.upgrade(config, 'head')
        with api.connect() as db:
            db.execute("INSERT INTO users(username,username_key,password_hash,nickname) VALUES ('old','old','unused','旧账号')")
        # Re-running Alembic is safe and does not reset data.
        command.upgrade(config, 'head')
        cls.client = TestClient(api.app)
        cls.client.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.client.__exit__(None, None, None)
        api.DSN = cls.original_dsn
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'DROP SCHEMA {cls.schema} CASCADE')

    def setUp(self):
        self.headers = []
        self.ids = []
        for _ in range(2):
            name = 'health_' + secrets.token_hex(6)
            password = secrets.token_urlsafe(18)
            created = self.client.post('/auth/register', json={'username': name, 'password': password})
            self.assertEqual(created.status_code, 201)
            self.assertEqual(created.json()['gender'], 'unset')
            logged = self.client.post('/auth/login', json={'username': name, 'password': password}).json()
            self.ids.append(logged['user']['id'])
            self.headers.append({'Authorization': 'Bearer ' + logged['token']})
        self.a, self.b = self.headers
        for headers in self.headers:
            self.assertEqual(self.client.put('/me', headers=headers,
                json={'nickname': '健康测试', 'gender': 'female'}).status_code, 200)

    def put_period(self, **changes):
        body = {'start_date': '2024-02-28', 'end_date': '2024-03-01',
                'bleeding_dates': ['2024-02-28', '2024-02-29', '2024-03-01']}
        body.update(changes)
        return self.client.put('/female-health/periods', headers=self.a, json=body)

    def snapshot(self, headers=None):
        response = self.client.get('/female-health', headers=headers or self.a)
        self.assertEqual(response.status_code, 200)
        return response.json()

    def test_migration_preserves_account_and_defaults_unset(self):
        with api.connect() as db:
            row = db.execute("SELECT nickname,gender FROM users WHERE username='old'").fetchone()
        self.assertEqual(row, {'nickname': '旧账号', 'gender': 'unset'})
        self.assertEqual(self.snapshot()['settings'], {'cycle_length': None, 'period_length': None, 'paused': False})

    def test_all_health_routes_require_authentication(self):
        for method, path, body in [
            ('GET', '/female-health', None), ('PUT', '/female-health/settings', {}),
            ('PUT', '/female-health/periods', {'start_date': '2024-01-01', 'bleeding_dates': ['2024-01-01']}),
            ('PUT', '/female-health/days', {'date': '2024-01-01'}),
            ('DELETE', '/female-health/periods?id=1', None),
            ('DELETE', '/female-health/days?date=2024-01-01', None),
            ('DELETE', '/female-health', None),
            ('PUT', '/me', {'nickname': '测试', 'gender': 'female'}),
        ]:
            with self.subTest(path=path, method=method):
                self.assertEqual(self.client.request(method, path, json=body).status_code, 401)

    def test_gender_hides_without_deleting_and_profile_validates(self):
        self.assertEqual(self.put_period().status_code, 200)
        for gender in ['male', 'unset']:
            self.assertEqual(self.client.put('/me', headers=self.a, json={'nickname': ' 保留 ', 'gender': gender}).json()['nickname'], '保留')
            self.assertEqual(self.client.get('/female-health', headers=self.a).status_code, 403)
            self.assertEqual(self.client.delete('/female-health', headers=self.a).status_code, 403)
        self.client.put('/me', headers=self.a, json={'nickname': '恢复', 'gender': 'female'})
        self.assertEqual(len(self.snapshot()['periods']), 1)
        self.assertEqual(self.client.get('/me', headers=self.a).json()['gender'], 'female')
        for body in [{'nickname': ' ', 'gender': 'female'}, {'nickname': '测试', 'gender': 'invalid'},
                     {'nickname': '测试', 'gender': 'female', 'user_id': self.ids[1]}]:
            self.assertEqual(self.client.put('/me', headers=self.a, json=body).status_code, 422)

    def test_cross_month_leap_day_retry_and_account_isolation(self):
        saved = self.put_period()
        self.assertEqual(saved.status_code, 200)
        self.assertEqual(self.put_period().json(), saved.json())
        self.assertEqual(len(self.snapshot()['periods']), 1)
        self.assertEqual(self.snapshot(self.b)['periods'], [])
        ident = saved.json()['id']
        foreign = self.client.put('/female-health/periods', headers=self.b, json={
            'id': ident, 'start_date': '2024-02-28', 'bleeding_dates': ['2024-02-28']})
        self.assertEqual(foreign.status_code, 404)
        self.client.delete('/female-health/periods', headers=self.b, params={'id': ident})
        self.assertEqual(len(self.snapshot()['periods']), 1)
        self.client.delete('/female-health/periods', headers=self.a, params={'id': ident})
        self.assertEqual(self.snapshot()['periods'], [])

    def test_validation_and_overlap_leave_data_intact(self):
        self.put_period()
        invalid = [
            {'end_date': '2024-02-27'},
            {'bleeding_dates': ['2024-02-29']},
            {'bleeding_dates': ['2024-02-28', '2024-02-28']},
            {'bleeding_dates': []},
            {'start_date': '1999-12-31', 'end_date': None, 'bleeding_dates': ['1999-12-31']},
            {'start_date': '2999-01-01', 'end_date': None, 'bleeding_dates': ['2999-01-01']},
            {'user_id': self.ids[1]},
        ]
        for body in invalid:
            with self.subTest(body=body):
                self.assertEqual(self.put_period(**body).status_code, 422)
        self.assertEqual(self.put_period(start_date='2024-02-29', end_date='2024-03-02',
            bleeding_dates=['2024-02-29', '2024-03-02']).status_code, 409)
        self.assertEqual(len(self.snapshot()['periods']), 1)

    def test_ongoing_dates_are_not_filled_and_can_be_finished(self):
        saved = self.put_period(start_date='2024-04-01', end_date=None, bleeding_dates=['2024-04-01'])
        self.assertEqual(self.snapshot()['periods'][0]['bleeding_dates'], ['2024-04-01'])
        self.assertEqual(self.put_period(start_date='2024-05-01', end_date=None, bleeding_dates=['2024-05-01']).status_code, 409)
        self.assertEqual(self.put_period(id=saved.json()['id'], start_date='2024-04-01', end_date='2024-04-04',
            bleeding_dates=['2024-04-01', '2024-04-04']).status_code, 200)
        self.assertEqual(self.snapshot()['periods'][0]['bleeding_dates'], ['2024-04-01', '2024-04-04'])
        self.assertEqual(self.put_period(start_date='2024-05-01', end_date=None, bleeding_dates=['2024-05-01']).status_code, 200)

    def test_concurrent_overlap_is_serialized(self):
        bodies = [dict(start_date=f'2024-06-0{n}', end_date='2024-06-05',
                       bleeding_dates=[f'2024-06-0{n}', '2024-06-05']) for n in [1, 2]]
        with ThreadPoolExecutor(max_workers=2) as pool:
            codes = list(pool.map(lambda body: self.client.put('/female-health/periods', headers=self.a, json=body).status_code, bodies))
        self.assertEqual(sorted(codes), [200, 409])
        self.assertEqual(len(self.snapshot()['periods']), 1)

    def test_daily_spotting_and_symptoms_do_not_create_period(self):
        day = {'date': '2024-02-29', 'spotting': True, 'symptoms': ['腹胀'], 'notes': '感受记录', 'pain': 1}
        self.assertEqual(self.client.put('/female-health/days', headers=self.a, json=day).status_code, 200)
        day['notes'] = '已修改'
        self.client.put('/female-health/days', headers=self.a, json=day)
        self.assertEqual(self.snapshot()['periods'], [])
        self.assertEqual(len(self.snapshot()['days']), 1)
        self.assertEqual(self.snapshot()['days'][0]['notes'], '已修改')
        self.client.delete('/female-health/days', headers=self.b, params={'date': day['date']})
        self.assertEqual(self.snapshot(self.b)['days'], [])
        self.assertEqual(len(self.snapshot()['days']), 1)
        self.client.delete('/female-health/days', headers=self.a, params={'date': day['date']})
        self.assertEqual(self.snapshot()['days'], [])
        for bad in [{'date': '2999-01-01'}, {'date': '2024-01-01', 'pain': True},
                    {'date': '2024-01-01', 'symptoms': ['腹胀', '腹胀']},
                    {'date': '2024-01-01', 'notes': 'a' * 2001}]:
            self.assertEqual(self.client.put('/female-health/days', headers=self.a, json=bad).status_code, 422)

    def test_settings_pause_reset_and_delete_isolation(self):
        settings = {'cycle_length': 30, 'period_length': 6, 'paused': True}
        self.assertEqual(self.client.put('/female-health/settings', headers=self.a, json=settings).status_code, 200)
        self.put_period()
        self.assertEqual(self.snapshot()['settings'], settings)
        self.assertIsNone(self.snapshot(self.b)['settings']['cycle_length'])
        self.client.delete('/female-health', headers=self.b, params={'reset_settings': 'true'})
        self.assertEqual(len(self.snapshot()['periods']), 1)
        self.client.delete('/female-health', headers=self.a)
        self.assertEqual(self.snapshot()['periods'], [])
        self.assertEqual(self.snapshot()['settings'], settings)
        self.client.delete('/female-health', headers=self.a, params={'reset_settings': 'true'})
        self.assertEqual(self.snapshot()['settings'], {'cycle_length': None, 'period_length': None, 'paused': False})
        for value in [0, 366, True, '28']:
            self.assertEqual(self.client.put('/female-health/settings', headers=self.a, json={'cycle_length': value}).status_code, 422)

    def test_expired_session_cannot_read_or_mutate(self):
        with api.connect() as db:
            db.execute("UPDATE user_sessions SET expires_at=now()-interval '1 second' WHERE user_id=%s", (self.ids[0],))
        self.assertEqual(self.client.get('/female-health', headers=self.a).status_code, 401)
        self.assertEqual(self.client.put('/female-health/settings', headers=self.a, json={}).status_code, 401)


if __name__ == '__main__':
    unittest.main()
