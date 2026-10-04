"""Journal HTTP checks against PostgreSQL in a disposable schema."""
import os
import secrets
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

import psycopg
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from psycopg.conninfo import make_conninfo
from pydantic import ValidationError

import app as api
from journal import JournalCreate, JournalUpdate, journal_today


class JournalValidationTests(unittest.TestCase):
    def test_whitespace_dates_and_todo_invariants(self):
        valid = dict(entry_date='2024-02-29', kind='diary', content='  正文\n🙂  ', client_request_id='a' * 32)
        self.assertEqual(JournalCreate(**valid).content, '正文\n🙂')
        for changes in [dict(content=' \n\t'), dict(is_todo=True), dict(completed=True),
                        dict(entry_date=(journal_today() + timedelta(days=1)).isoformat()),
                        dict(entry_date='2024-02-30'), dict(entry_date=0),
                        dict(entry_date='2024-02-29T00:00:00Z'), dict(is_todo=1),
                        dict(user_id=1), dict(title='x' * 101), dict(content='x' * 20001)]:
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                JournalCreate(**(valid | changes))
        memo = valid | dict(kind='memo', content='', title='安排', is_todo=True)
        JournalCreate(**memo)
        with self.assertRaises(ValidationError):
            JournalCreate(**(memo | dict(is_todo=False, completed=True)))
        with self.assertRaises(ValidationError):
            JournalUpdate(**{k: v for k, v in valid.items() if k != 'client_request_id'}, expected_version=True)


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), 'TEST_DATABASE_URL must name a test database')
class JournalApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_dsn = os.environ['TEST_DATABASE_URL']
        cls.schema = 'journal_test_' + secrets.token_hex(6)
        cls.original_dsn = api.DSN
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'CREATE SCHEMA {cls.schema}')
        cls.addClassCleanup(cls.cleanup)
        api.DSN = make_conninfo(cls.base_dsn, options=f'-csearch_path={cls.schema}')
        cls.config = Config(str(Path(__file__).with_name('alembic.ini')))
        cls.config.attributes['database_url'] = api.DSN
        command.upgrade(cls.config, 'head')
        cls.client = TestClient(api.app)
        cls.client.__enter__()
        cls.addClassCleanup(lambda: cls.client.__exit__(None, None, None))

    @classmethod
    def cleanup(cls):
        api.DSN = cls.original_dsn
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'DROP SCHEMA {cls.schema} CASCADE')

    def setUp(self):
        self.headers = []
        for _ in range(2):
            name = 'journal_' + secrets.token_hex(6)
            password = secrets.token_urlsafe(18)
            self.assertEqual(self.client.post('/auth/register', json={'username': name, 'password': password}).status_code, 201)
            result = self.client.post('/auth/login', json={'username': name, 'password': password}).json()
            self.headers.append({'Authorization': 'Bearer ' + result['token']})
        self.a, self.b = self.headers

    def body(self, **changes):
        return dict(entry_date='2024-02-29', kind='diary', title='记录', content='跑步\n🙂',
                    is_todo=False, completed=False, client_request_id=secrets.token_hex(16)) | changes

    def create(self, **changes):
        response = self.client.post('/journal/entries', headers=self.a, json=self.body(**changes))
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def update_body(self, row, **changes):
        return {key: row[key] for key in ['entry_date', 'kind', 'title', 'content', 'is_todo', 'completed']} | dict(expected_version=row['version']) | changes

    def test_auth_and_cross_account_read_write_delete(self):
        row = self.create()
        for method, path, body in [
            ('GET', '/journal/calendar?month=2024-02', None), ('GET', '/journal/entries', None),
            ('GET', f"/journal/entries/{row['id']}", None), ('POST', '/journal/entries', self.body()),
            ('PUT', f"/journal/entries/{row['id']}", self.update_body(row)),
            ('DELETE', f"/journal/entries/{row['id']}?expected_version=1", None)]:
            self.assertEqual(self.client.request(method, path, json=body).status_code, 401)
        for method, body in [('GET', None), ('PUT', self.update_body(row)), ('DELETE', None)]:
            self.assertEqual(self.client.request(method, f"/journal/entries/{row['id']}?expected_version=1", headers=self.b, json=body).status_code, 404)
        self.assertEqual(self.client.get('/journal/entries', headers=self.b).json()['total'], 0)
        self.assertEqual(self.client.get('/journal/calendar?month=2024-02', headers=self.b).json()['days'], [])

    def test_create_retry_is_atomic_and_hash_survives_edits(self):
        body = self.body()
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: self.client.post('/journal/entries', headers=self.a, json=body), range(2)))
        self.assertEqual([response.status_code for response in responses], [201, 201])
        row = responses[0].json()
        self.assertEqual(row['id'], responses[1].json()['id'])
        self.assertEqual(self.client.get('/journal/entries', headers=self.a).json()['total'], 1)
        updated = self.client.put(f"/journal/entries/{row['id']}", headers=self.a, json=self.update_body(row, content='修改后的内容'))
        self.assertEqual(updated.status_code, 200)
        self.assertEqual(self.client.post('/journal/entries', headers=self.a, json=body).json()['id'], row['id'])
        self.assertEqual(self.client.post('/journal/entries', headers=self.a, json=body | dict(title='不同')).status_code, 409)
        self.assertEqual(self.client.post('/journal/entries', headers=self.b, json=body).status_code, 201)

    def test_conflicting_updates_delete_and_date_move(self):
        row = self.create()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda content: self.client.put(f"/journal/entries/{row['id']}", headers=self.a,
                json=self.update_body(row, content=content, entry_date='2024-03-01')), ['甲', '乙']))
        self.assertEqual(sorted(result.status_code for result in results), [200, 409])
        self.assertEqual(self.client.get('/journal/calendar?month=2024-02', headers=self.a).json()['days'], [])
        self.assertEqual(self.client.get('/journal/calendar?month=2024-03', headers=self.a).json()['days'][0]['diaries'], 1)
        self.assertEqual(self.client.delete(f"/journal/entries/{row['id']}?expected_version=1", headers=self.a).status_code, 409)
        self.assertEqual(self.client.delete(f"/journal/entries/{row['id']}?expected_version=2", headers=self.a).status_code, 200)
        self.assertEqual(self.client.get(f"/journal/entries/{row['id']}", headers=self.a).status_code, 404)

    def test_todo_summary_order_pagination_and_literal_search(self):
        diary = self.create(content='特殊字符 100% _ \\ 中文')
        self.create(kind='memo', title='普通备忘')
        pending = self.create(kind='memo', title='未完成', is_todo=True)
        self.create(kind='memo', title='完成', is_todo=True, completed=True)
        future = self.create(kind='memo', entry_date=(journal_today() + timedelta(days=1)).isoformat())
        self.assertEqual(future['kind'], 'memo')
        page = self.client.get('/journal/entries?date=2024-02-29&limit=1', headers=self.a).json()
        self.assertEqual(page['items'][0]['id'], pending['id'])
        self.assertEqual(page['total'], 4)
        self.assertTrue(page['has_more'])
        all_ids = [self.client.get(f'/journal/entries?date=2024-02-29&limit=1&offset={n}', headers=self.a).json()['items'][0]['id'] for n in range(4)]
        self.assertEqual(len(set(all_ids)), 4)
        summary = self.client.get('/journal/calendar?month=2024-02', headers=self.a).json()['days'][0]
        self.assertEqual(summary, dict(entry_date='2024-02-29', diaries=1, memos=1, pending=1, completed=1))
        for keyword in ['%', '_', '\\', '中文']:
            rows = self.client.get('/journal/entries', params={'q': keyword}, headers=self.a).json()['items']
            self.assertEqual([row['id'] for row in rows], [diary['id']])
        for month in ['2024-13', '1999-12', '2999-01', 'bad']:
            self.assertEqual(self.client.get('/journal/calendar', params={'month': month}, headers=self.a).status_code, 422)
        self.assertEqual(self.client.get('/journal/entries?limit=101', headers=self.a).status_code, 422)

    def test_database_constraints_and_nonempty_downgrade_guard(self):
        row = self.create()
        with self.assertRaises(psycopg.errors.CheckViolation):
            with api.connect() as db:
                db.execute('UPDATE journal_entries SET completed=true WHERE id=%s', (row['id'],))
        with self.assertRaisesRegex(RuntimeError, 'would delete records'):
            command.downgrade(self.config, '0001_baseline')
        command.upgrade(self.config, 'head')
        self.assertEqual(self.client.get(f"/journal/entries/{row['id']}", headers=self.a).status_code, 200)


if __name__ == '__main__':
    unittest.main()
