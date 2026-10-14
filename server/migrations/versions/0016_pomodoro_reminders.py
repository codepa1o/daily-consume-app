"""为番茄钟保存用户订阅的定时提醒。"""
from alembic import op
from sqlalchemy import text


revision = '0016_pomodoro_reminders'
down_revision = '0015_wechat_identity'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE pomodoro_reminders (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        app_id TEXT NOT NULL,
        request_id CHAR(32) NOT NULL CHECK (request_id ~ '^[a-f0-9]{32}$'),
        template_id TEXT NOT NULL,
        phase TEXT NOT NULL CHECK (phase IN ('focus','shortBreak','longBreak')),
        task_title TEXT NOT NULL DEFAULT '' CHECK (char_length(task_title) <= 120),
        trigger_at TIMESTAMPTZ NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
            CHECK (status IN ('pending','sending','sent','cancelled','failed')),
        attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
        error_message TEXT NOT NULL DEFAULT '',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        sent_at TIMESTAMPTZ,
        UNIQUE (user_id, request_id)
    )''')
    op.execute('''CREATE INDEX pomodoro_reminders_due
        ON pomodoro_reminders(status, trigger_at)''')


def downgrade():
    if op.get_bind().execute(text(
            'SELECT EXISTS (SELECT 1 FROM pomodoro_reminders)')).scalar():
        raise RuntimeError('Downgrade would delete scheduled Pomodoro reminders.')
    op.drop_index('pomodoro_reminders_due', table_name='pomodoro_reminders')
    op.drop_table('pomodoro_reminders')
