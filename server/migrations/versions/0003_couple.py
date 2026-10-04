"""Private two-person spaces and their photo memories."""
from alembic import op
from sqlalchemy import text

revision = '0003_couple'
down_revision = '0002_journal'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE couple_spaces (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 60),
        since_date DATE NOT NULL CHECK (since_date >= DATE '2000-01-01'),
        created_by BIGINT NOT NULL REFERENCES users(id),
        invite_hash TEXT UNIQUE,
        invite_expires_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )''')
    op.execute('''CREATE TABLE couple_members (
        user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        space_id BIGINT NOT NULL REFERENCES couple_spaces(id) ON DELETE CASCADE,
        slot SMALLINT NOT NULL CHECK (slot IN (1,2)),
        UNIQUE(space_id,slot)
    )''')
    op.execute('''CREATE TABLE couple_memories (
        id BIGSERIAL PRIMARY KEY,
        space_id BIGINT NOT NULL REFERENCES couple_spaces(id) ON DELETE CASCADE,
        author_id BIGINT NOT NULL REFERENCES users(id),
        memory_date DATE NOT NULL CHECK (memory_date >= DATE '2000-01-01'),
        title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 100),
        content TEXT NOT NULL DEFAULT '' CHECK (char_length(content) <= 5000),
        mood TEXT NOT NULL DEFAULT '' CHECK (char_length(mood) <= 20),
        photo BYTEA,
        thumbnail BYTEA,
        client_request_id TEXT NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        request_hash TEXT NOT NULL CHECK (char_length(request_hash)=64),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE(author_id,client_request_id),
        CHECK ((photo IS NULL) = (thumbnail IS NULL)),
        CHECK (photo IS NULL OR octet_length(photo) <= 8388608)
    )''')
    op.execute('CREATE INDEX couple_memories_date ON couple_memories(space_id,memory_date DESC,id DESC)')
    op.execute('''CREATE TABLE couple_comments (
        id BIGSERIAL PRIMARY KEY,
        memory_id BIGINT NOT NULL REFERENCES couple_memories(id) ON DELETE CASCADE,
        author_id BIGINT NOT NULL REFERENCES users(id),
        content TEXT NOT NULL CHECK (char_length(content) BETWEEN 1 AND 1000),
        client_request_id TEXT NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE(author_id,client_request_id)
    )''')
    op.execute('CREATE INDEX couple_comments_memory ON couple_comments(memory_id,id)')
    op.execute('''CREATE TABLE couple_reactions (
        memory_id BIGINT NOT NULL REFERENCES couple_memories(id) ON DELETE CASCADE,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        emoji TEXT NOT NULL CHECK (emoji IN ('❤️','抱抱','想你','开心')),
        PRIMARY KEY(memory_id,user_id)
    )''')


def downgrade():
    if op.get_bind().execute(text('SELECT EXISTS (SELECT 1 FROM couple_spaces)')).scalar():
        raise RuntimeError('Couple downgrade would delete records; roll back the application instead.')
    for table in ('couple_reactions', 'couple_comments', 'couple_memories', 'couple_members', 'couple_spaces'):
        op.drop_table(table)
