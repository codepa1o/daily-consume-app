"""Add account-owned diary, memo and todo records."""
from alembic import op
from sqlalchemy import text

revision = '0002_journal'
down_revision = '0001_baseline'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE journal_entries (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        entry_date DATE NOT NULL CHECK (entry_date >= DATE '2000-01-01'),
        kind TEXT NOT NULL CHECK (kind IN ('diary', 'memo')),
        title TEXT NOT NULL CHECK (char_length(title) <= 100),
        content TEXT NOT NULL CHECK (char_length(content) <= 20000),
        is_todo BOOLEAN NOT NULL DEFAULT false,
        completed BOOLEAN NOT NULL DEFAULT false,
        version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
        client_request_id TEXT NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        request_hash TEXT NOT NULL CHECK (char_length(request_hash) = 64),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (user_id, client_request_id),
        CHECK (kind <> 'diary' OR (NOT is_todo AND NOT completed AND content ~ '[^[:space:]]')),
        CHECK (kind <> 'memo' OR title ~ '[^[:space:]]' OR content ~ '[^[:space:]]'),
        CHECK (NOT completed OR is_todo)
    )''')
    op.execute('CREATE INDEX journal_entries_date ON journal_entries(user_id, entry_date, created_at, id)')


def downgrade():
    if op.get_bind().execute(text('SELECT EXISTS (SELECT 1 FROM journal_entries)')).scalar():
        raise RuntimeError('Journal downgrade would delete records; retain the table and roll back the application instead.')
    op.drop_table('journal_entries')
