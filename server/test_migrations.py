"""Real PostgreSQL migration tests, isolated in disposable schemas.

TEST_DATABASE_URL must point to a test database whose owner can create schemas.
Run: python -m unittest discover -s server -p 'test_*.py' -v
"""
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import psycopg
from alembic import command
from alembic.config import Config
from psycopg import sql
from psycopg.conninfo import make_conninfo

SERVER = Path(__file__).resolve().parent
BASELINE_SQL = (SERVER / 'migrations/versions/0001_schema.sql').read_text(encoding='utf-8')


@unittest.skipUnless(os.environ.get('TEST_DATABASE_URL'), 'TEST_DATABASE_URL must name a test database')
class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.base_dsn = os.environ['TEST_DATABASE_URL']
        self.schema = 'migration_test_' + secrets.token_hex(6)
        with psycopg.connect(self.base_dsn) as db:
            db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(self.schema)))
        self.addCleanup(self.drop_schema)
        self.dsn = make_conninfo(self.base_dsn, options=f'-csearch_path={self.schema}')
        self.config = Config(str(SERVER / 'alembic.ini'))
        self.config.attributes['database_url'] = self.dsn

    def drop_schema(self):
        with psycopg.connect(self.base_dsn) as db:
            db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(self.schema)))

    def execute(self, statement):
        with psycopg.connect(self.dsn) as db:
            return db.execute(statement).fetchall()

    def install_legacy_schema(self):
        with psycopg.connect(self.dsn) as db:
            db.execute(BASELINE_SQL)

    def assert_unversioned(self):
        self.assertEqual(self.execute("SELECT to_regclass('alembic_version')"), [(None,)])

    def test_empty_database_and_repeat_upgrade(self):
        command.upgrade(self.config, 'head')
        command.upgrade(self.config, 'head')
        self.assertEqual(self.execute('SELECT version_num FROM alembic_version'), [('0003_couple',)])
        self.assertEqual(self.execute("SELECT count(*) FROM pg_tables WHERE schemaname=current_schema()"), [(20,)])
        self.assertEqual(self.execute("INSERT INTO users(username,username_key,password_hash,nickname) "
                                     "VALUES ('new','new','hash','新账号') RETURNING id,gender"), [(1, 'unset')])

    def test_adoption_preserves_rows_and_sequence(self):
        self.install_legacy_schema()
        self.execute("INSERT INTO users(username,username_key,password_hash,nickname) "
                     "VALUES ('old','old','hash','旧账号') RETURNING id")
        self.execute("INSERT INTO meal_entries VALUES (1,'2024-02-29','午餐','米饭',1200) RETURNING user_id")
        self.execute("INSERT INTO menstrual_periods(user_id,start_date,bleeding_dates) "
                     "VALUES (1,'2024-02-29','[\"2024-02-29\"]') RETURNING id")
        with psycopg.connect(self.dsn) as db:
            db.execute("""INSERT INTO user_sessions(token_hash,user_id,expires_at)
                VALUES (repeat('a',64),1,now()+interval '1 day');
                INSERT INTO weight_entries VALUES (1,'2024-02-29',60000);
                INSERT INTO height_entries VALUES (1,'2024-02-29',1700);
                INSERT INTO workout_muscles VALUES (1,'胸',4294967295,1);
                INSERT INTO workout_plans VALUES (1,1,'[]',0);
                INSERT INTO workout_logs VALUES (1,'2024-02-29','[]');
                INSERT INTO workout_settings VALUES (1,3);
                INSERT INTO legacy_imports(import_id,user_id,counts) VALUES (repeat('b',64),1,'{}');
                INSERT INTO female_health_settings VALUES (1,28,5,false);
                INSERT INTO female_health_days VALUES
                    (1,'2024-02-29','light',1,'[]','平静',false,'记录');""")
        before = {table: self.execute(f'SELECT * FROM {table}')
                  for table in re.findall(r'CREATE TABLE (\w+)', BASELINE_SQL)}
        command.upgrade(self.config, 'head')
        command.upgrade(self.config, 'head')
        for table, rows in before.items():
            self.assertEqual(self.execute(f'SELECT * FROM {table}'), rows)
        self.assertEqual(self.execute("INSERT INTO users(username,username_key,password_hash,nickname) "
                                     "VALUES ('next','next','hash','新账号') RETURNING id"), [(2,)])

    def test_concurrent_cli_upgrades_are_serialized(self):
        environment = dict(os.environ, DATABASE_URL=self.dsn, PYTHONUTF8='1')
        processes = [subprocess.Popen(
            [sys.executable, '-m', 'alembic', '-c', str(SERVER / 'alembic.ini'), 'upgrade', 'head'],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            for _ in range(2)]
        try:
            for process in processes:
                stdout, stderr = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 0, (stdout + stderr).decode('utf-8'))
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertEqual(self.execute('SELECT version_num FROM alembic_version'), [('0003_couple',)])

    def test_partial_schema_is_rejected_without_changes(self):
        with psycopg.connect(self.dsn) as db:
            db.execute('CREATE TABLE users(id BIGSERIAL PRIMARY KEY)')
            db.execute('INSERT INTO users DEFAULT VALUES')
        with self.assertRaisesRegex(RuntimeError, 'Baseline table mismatch'):
            command.upgrade(self.config, 'head')
        self.assertEqual(self.execute('SELECT * FROM users'), [(1,)])
        self.assert_unversioned()

    def test_structure_drift_is_rejected_without_stamping(self):
        changes = {
            'column': "ALTER TABLE users ALTER COLUMN gender DROP NOT NULL",
            'default': "ALTER TABLE users ALTER COLUMN gender SET DEFAULT 'female'",
            'constraint': 'ALTER TABLE weight_entries DROP CONSTRAINT weight_entries_grams_check',
            'index': 'DROP INDEX user_sessions_expiry',
            'sequence': 'ALTER SEQUENCE users_id_seq INCREMENT BY 2',
        }
        for kind, statement in changes.items():
            with self.subTest(kind=kind):
                self.install_legacy_schema()
                with psycopg.connect(self.dsn) as db:
                    db.execute(statement)
                with self.assertRaisesRegex(RuntimeError, 'Baseline structure mismatch'):
                    command.upgrade(self.config, 'head')
                self.assert_unversioned()
                with psycopg.connect(self.dsn) as db:
                    db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(self.schema)))
                    db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(self.schema)))

    def test_baseline_downgrade_cannot_delete_business_data(self):
        command.upgrade(self.config, 'head')
        with self.assertRaisesRegex(RuntimeError, 'baseline is irreversible'):
            command.downgrade(self.config, 'base')
        self.assertEqual(self.execute('SELECT version_num FROM alembic_version'), [('0003_couple',)])
        self.assertEqual(self.execute('SELECT count(*) FROM users'), [(0,)])

    def test_incremental_upgrade_downgrade_and_failed_transaction(self):
        # A disposable revision chain exercises the real environment and template.
        with tempfile.TemporaryDirectory(prefix='daily_consume_migrations_') as directory:
            migrations = Path(directory) / 'migrations'
            shutil.copytree(SERVER / 'migrations', migrations, ignore=shutil.ignore_patterns('__pycache__'))
            self.config.set_main_option('script_location', str(migrations))
            command.upgrade(self.config, 'head')
            script = command.revision(self.config, message='add test column', rev_id='0002_test')
            source = Path(script.path).read_text(encoding='utf-8')
            source = source.replace("raise NotImplementedError('Write and review the upgrade operations.')",
                                    "op.add_column('users', sa.Column('migration_note', sa.Text()))")
            source = source.replace("raise NotImplementedError('Write the reverse operations, or explain why this migration is irreversible.')",
                                    "op.drop_column('users', 'migration_note')")
            Path(script.path).write_text(source, encoding='utf-8')
            command.upgrade(self.config, 'head')
            self.assertEqual(self.execute('SELECT migration_note FROM users'), [])
            command.downgrade(self.config, '-1')
            self.assertEqual(self.execute('SELECT version_num FROM alembic_version'), [('0003_couple',)])
            # A failure after DDL must roll back both the column and version update.
            Path(script.path).write_text(source.replace("op.add_column('users', sa.Column('migration_note', sa.Text()))",
                "op.add_column('users', sa.Column('migration_note', sa.Text()))\n    raise RuntimeError('deliberate failure')"),
                encoding='utf-8')
            with self.assertRaisesRegex(RuntimeError, 'deliberate failure'):
                command.upgrade(self.config, 'head')
            self.assertEqual(self.execute('SELECT version_num FROM alembic_version'), [('0003_couple',)])
            self.assertEqual(self.execute("SELECT count(*) FROM information_schema.columns "
                "WHERE table_schema=current_schema() AND table_name='users' AND column_name='migration_note'"), [(0,)])


if __name__ == '__main__':
    unittest.main()
