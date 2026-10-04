"""Add account-owned Pomodoro tasks and focus history."""
from alembic import op
from sqlalchemy import text

revision = '0005_pomodoro'
down_revision = '0004_avatar'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE pomodoro_settings (
        user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        focus_minutes SMALLINT NOT NULL DEFAULT 25 CHECK (focus_minutes BETWEEN 1 AND 120),
        short_break_minutes SMALLINT NOT NULL DEFAULT 5 CHECK (short_break_minutes BETWEEN 1 AND 60),
        long_break_minutes SMALLINT NOT NULL DEFAULT 15 CHECK (long_break_minutes BETWEEN 1 AND 120),
        rounds_per_long_break SMALLINT NOT NULL DEFAULT 4 CHECK (rounds_per_long_break BETWEEN 2 AND 12)
    )''')
    op.execute('''CREATE TABLE pomodoro_tasks (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120 AND title ~ '[^[:space:]]'),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )''')
    op.execute('CREATE UNIQUE INDEX pomodoro_tasks_title ON pomodoro_tasks(user_id,lower(title))')
    op.execute('''CREATE TABLE pomodoro_sessions (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        task_id BIGINT REFERENCES pomodoro_tasks(id) ON DELETE SET NULL,
        client_request_id CHAR(32) NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        task_title TEXT NOT NULL CHECK (char_length(task_title) BETWEEN 1 AND 120 AND task_title ~ '[^[:space:]]'),
        duration_minutes SMALLINT NOT NULL CHECK (duration_minutes BETWEEN 1 AND 120),
        started_at TIMESTAMPTZ NOT NULL,
        completed_at TIMESTAMPTZ NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (user_id,client_request_id),
        CHECK (completed_at > started_at)
    )''')
    op.execute('CREATE INDEX pomodoro_sessions_started ON pomodoro_sessions(user_id,started_at DESC,id DESC)')


def downgrade():
    if op.get_bind().execute(text('SELECT EXISTS (SELECT 1 FROM pomodoro_sessions)')).scalar():
        raise RuntimeError('Pomodoro downgrade would delete focus history; roll back the application instead.')
    if op.get_bind().execute(text('SELECT EXISTS (SELECT 1 FROM pomodoro_tasks)')).scalar():
        raise RuntimeError('Pomodoro downgrade would delete saved tasks; roll back the application instead.')
    if op.get_bind().execute(text('SELECT EXISTS (SELECT 1 FROM pomodoro_settings)')).scalar():
        raise RuntimeError('Pomodoro downgrade would delete saved settings; roll back the application instead.')
    op.drop_table('pomodoro_sessions')
    op.drop_table('pomodoro_tasks')
    op.drop_table('pomodoro_settings')
