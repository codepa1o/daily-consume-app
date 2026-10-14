"""Skill Agent 输入校验和账号隔离检查。"""
import os
import secrets
import unittest
from pathlib import Path

from pydantic import ValidationError

from skill_agent.engine import SkillAgentError, github_url_to_raw_url
from skill_agent.knowledge import parse_document, split_chunks
from skill_agent.router import CaseInput, ConversationCreate, MessageInput


class SkillAgentValidationTests(unittest.TestCase):
    def test_github_skill_links_are_restricted(self):
        self.assertEqual(
            github_url_to_raw_url('https://github.com/owner/repo/blob/main/SKILL.md'),
            'https://raw.githubusercontent.com/owner/repo/main/SKILL.md',
        )
        self.assertEqual(
            github_url_to_raw_url('https://raw.githubusercontent.com/owner/repo/main/SKILL.md'),
            'https://raw.githubusercontent.com/owner/repo/main/SKILL.md',
        )
        for value in ('http://github.com/owner/repo/blob/main/SKILL.md',
                      'https://example.com/SKILL.md',
                      'https://github.com/owner/repo/blob/main/README.md'):
            with self.subTest(value=value), self.assertRaises(SkillAgentError):
                github_url_to_raw_url(value)

    def test_api_inputs_trim_and_reject_empty_or_extra_fields(self):
        conversation = ConversationCreate(
            skill_url=' https://github.com/owner/repo/blob/main/SKILL.md ',
            title=' 规划对话 ',
        )
        self.assertEqual(conversation.title, '规划对话')
        with self.assertRaises(ValidationError):
            ConversationCreate(skill_url='  ')
        with self.assertRaises(ValidationError):
            MessageInput(question=' \n ')
        with self.assertRaises(ValidationError):
            CaseInput(title='x', question='q', expected_behavior='e',
                      scoring_focus='s', user_id=1)

    def test_document_types_limits_and_page_aware_chunks(self):
        kind, sections = parse_document('notes.md', b'# Topic\n\nA short paragraph.')
        self.assertEqual(kind, 'md')
        self.assertEqual(sections[0][0], 0)
        chunks = split_chunks([(1, 'First page content.'), (2, 'Second page content.')])
        self.assertEqual([item['page_number'] for item in chunks], [1, 2])
        with self.assertRaises(SkillAgentError):
            parse_document('notes.exe', b'not supported')
        with self.assertRaises(SkillAgentError):
            parse_document('large.txt', b'x' * (10 * 1024 * 1024 + 1))


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'),
                     'TEST_DATABASE_URL must name a test database')
class SkillAgentAccountApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import psycopg
        from alembic import command
        from alembic.config import Config
        from fastapi.testclient import TestClient
        from psycopg.conninfo import make_conninfo
        import app as api

        cls.api = api
        cls.base_dsn = os.environ['TEST_DATABASE_URL']
        cls.schema = 'skill_agent_test_' + secrets.token_hex(6)
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'CREATE SCHEMA {cls.schema}')
        cls.original_dsn = api.DSN
        api.DSN = make_conninfo(cls.base_dsn, options=f'-csearch_path={cls.schema}')
        cls.original_worker_setting = os.environ.get('SKILL_AGENT_WORKER_ENABLED')
        os.environ['SKILL_AGENT_WORKER_ENABLED'] = 'false'
        config = Config(str(Path(__file__).with_name('alembic.ini')))
        config.attributes['database_url'] = api.DSN
        command.upgrade(config, 'head')
        cls.client = TestClient(api.app)
        cls.client.__enter__()

    @classmethod
    def tearDownClass(cls):
        import psycopg

        cls.client.__exit__(None, None, None)
        cls.api.DSN = cls.original_dsn
        if cls.original_worker_setting is None:
            os.environ.pop('SKILL_AGENT_WORKER_ENABLED', None)
        else:
            os.environ['SKILL_AGENT_WORKER_ENABLED'] = cls.original_worker_setting
        with psycopg.connect(cls.base_dsn) as db:
            db.execute(f'DROP SCHEMA {cls.schema} CASCADE')

    def setUp(self):
        self.headers = []
        for _ in range(2):
            name = 'skill_' + secrets.token_hex(5)
            password = secrets.token_urlsafe(18)
            self.assertEqual(self.client.post('/auth/register', json={
                'username': name, 'password': password,
            }).status_code, 201)
            response = self.client.post('/auth/login', json={
                'username': name, 'password': password,
            })
            self.headers.append({'Authorization': 'Bearer ' + response.json()['token']})

    def test_conversation_routes_require_owner(self):
        self.assertEqual(self.client.get('/skill-agent/conversations').status_code, 401)
        created = self.client.post('/skill-agent/conversations', headers=self.headers[0], json={
            'skill_url': 'https://github.com/owner/repo/blob/main/SKILL.md',
            'title': '私有对话',
        })
        self.assertEqual(created.status_code, 201, created.text)
        conversation_id = created.json()['id']
        self.assertEqual(self.client.get(
            f'/skill-agent/conversations/{conversation_id}', headers=self.headers[1]
        ).status_code, 404)
        self.assertEqual(self.client.patch(
            f'/skill-agent/conversations/{conversation_id}', headers=self.headers[1],
            json={'title': '越权修改'},
        ).status_code, 404)
        self.assertEqual(self.client.put(
            f'/skill-agent/conversations/{conversation_id}', headers=self.headers[1],
            json={'title': '越权修改'},
        ).status_code, 404)
        self.assertEqual(self.client.put(
            f'/skill-agent/conversations/{conversation_id}', headers=self.headers[0],
            json={'title': '小程序更新标题'},
        ).status_code, 200)
        self.assertEqual(self.client.delete(
            f'/skill-agent/conversations/{conversation_id}', headers=self.headers[1]
        ).status_code, 404)
        self.assertEqual(self.client.get(
            '/skill-agent/conversations', headers=self.headers[1]
        ).json(), [])


if __name__ == '__main__':
    unittest.main()
