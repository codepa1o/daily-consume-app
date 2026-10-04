"""Private album validation and real PostgreSQL HTTP checks."""
import base64
import io
import os
import secrets
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

import psycopg
from alembic import command
from alembic.config import Config
from fastapi import HTTPException
from fastapi.testclient import TestClient
from PIL import Image
from psycopg.conninfo import make_conninfo
from pydantic import ValidationError

import app as api
from couple import CommentInput, InviteInput, MemoryInput, SpaceInput, prepare_photo, today


def photo_input():
    output = io.BytesIO()
    exif = Image.Exif()
    exif[270] = 'private metadata'
    Image.new('RGB', (1900, 1200), (180, 100, 80)).save(output, 'JPEG', exif=exif)
    return base64.b64encode(output.getvalue()).decode()


class CoupleValidationTests(unittest.TestCase):
    def test_dates_text_and_unknown_fields(self):
        body = dict(memory_date='2024-02-29', title=' 回忆 ', client_request_id='a' * 32)
        self.assertEqual(MemoryInput(**body).title, '回忆')
        for change in [dict(title='  '), dict(author_id=4), dict(memory_date='2024-02-30'),
                       dict(memory_date=(today() + timedelta(days=1)).isoformat()),
                       dict(memory_date=1759536000), dict(title='x' * 101), dict(mood='other'),
                       dict(client_request_id='a' * 31), dict(photo_base64='a' * 11184813)]:
            with self.subTest(change=list(change)), self.assertRaises(ValidationError):
                MemoryInput(**(body | change))
        with self.assertRaises(ValidationError):
            SpaceInput(since_date='1999-12-31')
        with self.assertRaises(ValidationError):
            CommentInput(content='\n ', client_request_id='b' * 32)
        self.assertEqual(InviteInput(code=' abcd23456789 ').code, 'ABCD23456789')

    def test_photo_resize_strip_metadata_and_reject_nonimage(self):
        full, thumb = prepare_photo(photo_input())
        for data, bound in [(full, 1600), (thumb, 400)]:
            image = Image.open(io.BytesIO(data))
            self.assertLessEqual(max(image.size), bound)
            self.assertEqual(image.format, 'JPEG')
            self.assertFalse(image.getexif())
        self.assertEqual(prepare_photo(None), (None, None))
        for value in ['bad base64!', '', base64.b64encode(b'not a photo').decode()]:
            with self.assertRaises(HTTPException) as caught:
                prepare_photo(value)
            self.assertEqual(caught.exception.status_code, 422)


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), 'TEST_DATABASE_URL must name a test database')
class CoupleApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_dsn = os.environ['TEST_DATABASE_URL']
        cls.schema = 'couple_test_' + secrets.token_hex(6)
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
        self.headers, self.users = [], []
        for _ in range(3):
            credentials = dict(username='couple_' + secrets.token_hex(5), password=secrets.token_urlsafe(18))
            self.assertEqual(self.client.post('/auth/register', json=credentials).status_code, 201)
            logged = self.client.post('/auth/login', json=credentials).json()
            self.headers.append({'Authorization': 'Bearer ' + logged['token']})
            self.users.append(logged['user']['id'])
        self.a, self.b, self.c = self.headers

    def start(self, join=True):
        response = self.client.post('/couple/space', headers=self.a,
                                    json={'title': '我们的回忆', 'since_date': '2024-02-29'})
        self.assertEqual(response.status_code, 201, response.text)
        code = self.client.post('/couple/invite', headers=self.a).json()['code']
        if join:
            self.assertEqual(self.client.post('/couple/join', headers=self.b, json={'code': code}).status_code, 200)
        return response.json(), code

    def body(self, **changes):
        return dict(memory_date='2024-02-29', title='夕阳', content='今天很开心',
                    mood='开心', client_request_id=secrets.token_hex(16), photo_base64=photo_input()) | changes

    def create(self, header=None, **changes):
        response = self.client.post('/couple/memories', headers=header or self.a, json=self.body(**changes))
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    def test_invite_confirmation_rotation_expiry_and_two_member_limit(self):
        self.assertEqual(self.client.get('/couple/space').status_code, 401)
        self.assertIsNone(self.client.get('/couple/space', headers=self.a).json())
        space, old = self.start(join=False)
        new = self.client.post('/couple/invite', headers=self.a).json()['code']
        self.assertEqual(self.client.post('/couple/invite/preview', headers=self.b, json={'code': old}).status_code, 404)
        preview = self.client.post('/couple/invite/preview', headers=self.b, json={'code': new}).json()
        self.assertEqual(preview['title'], space['title'])
        self.assertIsNone(self.client.get('/couple/space', headers=self.b).json())
        with api.connect() as db:
            db.execute("UPDATE couple_spaces SET invite_expires_at=now()-interval '1 second' WHERE id=%s", (space['id'],))
        self.assertEqual(self.client.post('/couple/join', headers=self.b, json={'code': new}).status_code, 404)
        new = self.client.post('/couple/invite', headers=self.a).json()['code']
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda h: self.client.post('/couple/join', headers=h, json={'code': new}).status_code, [self.b, self.c]))
        self.assertEqual(results.count(200), 1)
        self.assertTrue(all(code in (200, 404, 409) for code in results), results)
        self.assertEqual(len(self.client.get('/couple/space', headers=self.a).json()['members']), 2)
        self.assertEqual(self.client.post('/couple/invite', headers=self.a).status_code, 409)
        self.assertEqual(self.client.post('/couple/space', headers=self.a, json={'since_date': '2024-02-29'}).status_code, 409)

    def test_third_account_cannot_read_photos_comment_react_or_delete(self):
        self.start()
        memory = self.create()
        ident = memory['id']
        self.assertEqual(self.client.get(f'/couple/memories/{ident}', headers=self.b).json()['content'], '今天很开心')
        photo = self.client.get(f'/couple/memories/{ident}/photo?thumbnail=false', headers=self.b)
        self.assertEqual(photo.status_code, 200)
        self.assertEqual(photo.headers['content-type'], 'image/jpeg')
        self.assertEqual(photo.headers['cache-control'], 'no-store')
        self.assertFalse(Image.open(io.BytesIO(photo.content)).getexif())
        for path in [f'/couple/memories/{ident}', f'/couple/memories/{ident}/photo']:
            self.assertEqual(self.client.get(path, headers=self.c).status_code, 404)
        self.assertEqual(self.client.get(f'/couple/memories/{ident}/photo').status_code, 401)
        self.assertEqual(self.client.post(f'/couple/memories/{ident}/comments', headers=self.c,
            json={'content': '不允许', 'client_request_id': secrets.token_hex(16)}).status_code, 404)
        self.assertEqual(self.client.put(f'/couple/memories/{ident}/reaction', headers=self.c, json={'emoji': '❤️'}).status_code, 404)
        self.assertEqual(self.client.delete(f'/couple/memories/{ident}', headers=self.c).status_code, 404)
        self.assertEqual(self.client.delete(f'/couple/memories/{ident}', headers=self.b).status_code, 403)
        self.assertEqual(self.client.get('/couple/memories', headers=self.c).status_code, 404)

    def test_idempotent_upload_comment_reaction_and_author_delete(self):
        self.start()
        body = self.body()
        with ThreadPoolExecutor(max_workers=2) as pool:
            rows = list(pool.map(lambda _: self.client.post('/couple/memories', headers=self.a, json=body), range(2)))
        self.assertTrue(all(r.status_code == 201 for r in rows), [r.text for r in rows])
        ident = rows[0].json()['id']
        self.assertEqual(rows[1].json()['id'], ident)
        self.assertEqual(self.client.post('/couple/memories', headers=self.a, json=body | {'content': '变更'}).status_code, 409)
        comment = dict(content='下次一起看', client_request_id=secrets.token_hex(16))
        first = self.client.post(f'/couple/memories/{ident}/comments', headers=self.b, json=comment)
        repeated = self.client.post(f'/couple/memories/{ident}/comments', headers=self.b, json=comment)
        self.assertEqual(first.json()['id'], repeated.json()['id'])
        self.assertEqual(self.client.post(f'/couple/memories/{ident}/comments', headers=self.b,
            json=comment | {'content': '更改'}).status_code, 409)
        for emoji in ['❤️', '想你', None]:
            self.assertEqual(self.client.put(f'/couple/memories/{ident}/reaction', headers=self.b, json={'emoji': emoji}).status_code, 200)
            detail = self.client.get(f'/couple/memories/{ident}', headers=self.a).json()
            self.assertEqual(len(detail['reactions']), 0 if emoji is None else 1)
            self.assertEqual(len(detail['comments']), 1)
        self.assertEqual(self.client.delete(f'/couple/memories/{ident}', headers=self.a).status_code, 200)
        self.assertEqual(self.client.get(f'/couple/memories/{ident}/photo', headers=self.b).status_code, 404)
        with api.connect() as db:
            self.assertEqual(db.execute('SELECT count(*) AS n FROM couple_comments WHERE memory_id=%s', (ident,)).fetchone()['n'], 0)

    def test_pair_uses_one_latest_photo_per_author_and_pagination(self):
        self.start()
        self.create()
        partner = self.create(self.b)
        latest = self.create()
        self.create(photo_base64=None, title='纯文字日记')
        pair = self.client.get('/couple/pair?date=2024-02-29', headers=self.a).json()['items']
        self.assertEqual({row['id'] for row in pair}, {partner['id'], latest['id']})
        page = self.client.get('/couple/memories?limit=2', headers=self.a).json()
        self.assertTrue(page['has_more'])
        following = self.client.get('/couple/memories?limit=2&offset=2', headers=self.b).json()
        self.assertFalse(following['has_more'])
        self.assertEqual(len({row['id'] for row in page['items'] + following['items']}), 4)
        self.assertEqual(self.client.get('/couple/pair?date=2999-01-01', headers=self.a).status_code, 422)
        self.assertEqual(self.client.get('/couple/memories?limit=101', headers=self.a).status_code, 422)
        with self.assertRaisesRegex(RuntimeError, 'would delete records'):
            command.downgrade(self.config, '0002_journal')
        command.upgrade(self.config, 'head')


if __name__ == '__main__':
    unittest.main()
