"""Other-expense API checks against PostgreSQL in a disposable schema."""
import os
import secrets
import unittest
from pathlib import Path

import psycopg
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from psycopg.conninfo import make_conninfo
from pydantic import ValidationError

import app as api
from app import OtherExpenseInput


class OtherExpenseValidationTests(unittest.TestCase):
    def test_category_and_amount_validation(self):
        row = OtherExpenseInput(date='2024-02-29', category='  交通  ', expense_cents=2500)
        self.assertEqual(row.category, '交通')
        for changes in [
            {'category': ' \t'},
            {'category': 'x' * 81},
            {'expense_cents': -1},
            {'expense_cents': 1.5},
            {'unexpected': True},
        ]:
            with self.subTest(changes=changes), self.assertRaises(ValidationError):
                OtherExpenseInput(**({'date': '2024-02-29', 'category': '交通', 'expense_cents': 2500} | changes))


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), 'TEST_DATABASE_URL must name a test database')
class OtherExpenseApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_dsn = os.environ['TEST_DATABASE_URL']
        cls.schema = 'other_expense_test_' + secrets.token_hex(6)
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
            username = 'expense_' + secrets.token_hex(6)
            password = secrets.token_urlsafe(18)
            response = self.client.post('/auth/register', json={'username': username, 'password': password})
            self.assertEqual(response.status_code, 201, response.text)
            login = self.client.post('/auth/login', json={'username': username, 'password': password})
            self.headers.append({'Authorization': 'Bearer ' + login.json()['token']})
        self.a, self.b = self.headers

    def test_crud_authentication_range_and_account_isolation(self):
        params = {'start': '2024-02-01', 'end': '2024-02-29'}
        self.assertEqual(self.client.get('/other-expenses', params=params).status_code, 401)
        self.assertEqual(self.client.get('/other-expenses', params={'start': '2024-03-01', 'end': '2024-02-01'}, headers=self.a).status_code, 422)

        body = {'date': '2024-02-29', 'category': '交通', 'expense_cents': 2500}
        created = self.client.post('/other-expenses', headers=self.a, json=body)
        self.assertEqual(created.status_code, 201, created.text)
        row = created.json()
        self.assertEqual((row['category'], row['expense_cents']), ('交通', 2500))
        self.assertEqual(self.client.get('/other-expenses', params=params, headers=self.a).json(), [row])
        self.assertEqual(self.client.get('/other-expenses', params=params, headers=self.b).json(), [])
        self.assertEqual(self.client.put(f"/other-expenses/{row['id']}", headers=self.b, json=body).status_code, 404)
        self.assertEqual(self.client.delete(f"/other-expenses/{row['id']}", headers=self.b).status_code, 404)

        changed = body | {'date': '2024-03-01', 'category': '日用品', 'expense_cents': 9000}
        updated = self.client.put(f"/other-expenses/{row['id']}", headers=self.a, json=changed)
        self.assertEqual(updated.status_code, 200, updated.text)
        self.assertEqual(updated.json()['category'], '日用品')
        self.assertEqual(self.client.get('/other-expenses', params=params, headers=self.a).json(), [])
        self.assertEqual(self.client.post('/other-expenses', headers=self.a, json=body | {'category': '  '}).status_code, 422)
        self.assertEqual(self.client.post('/other-expenses', headers=self.a, json=body | {'expense_cents': -1}).status_code, 422)
        self.assertEqual(self.client.delete(f"/other-expenses/{row['id']}", headers=self.a).status_code, 200)
        self.assertEqual(self.client.delete(f"/other-expenses/{row['id']}", headers=self.a).status_code, 404)


if __name__ == '__main__':
    unittest.main()
