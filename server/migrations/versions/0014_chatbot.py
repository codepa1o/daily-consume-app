"""Add account-scoped chatbot conversations and messages."""
from alembic import op
from sqlalchemy import text


revision = '0014_chatbot'
down_revision = '0013_couple_conflicts'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE chatbot_conversations (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        title TEXT NOT NULL DEFAULT '新对话'
            CHECK (char_length(title) BETWEEN 1 AND 80),
        memory_summary TEXT NOT NULL DEFAULT '',
        memory_last_message_id BIGINT NOT NULL DEFAULT 0,
        memory_updated_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (id, user_id)
    )''')
    op.execute('''CREATE INDEX chatbot_conversations_recent
        ON chatbot_conversations(user_id, updated_at DESC, id DESC)''')

    op.execute('''CREATE TABLE chatbot_messages (
        id BIGSERIAL PRIMARY KEY,
        conversation_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
        content TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL CHECK (status IN ('complete', 'streaming', 'failed', 'cancelled')),
        metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
        error_message TEXT NOT NULL DEFAULT '',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        FOREIGN KEY (conversation_id, user_id)
            REFERENCES chatbot_conversations(id, user_id) ON DELETE CASCADE
    )''')
    op.execute('''CREATE INDEX chatbot_messages_history
        ON chatbot_messages(user_id, conversation_id, id)''')
    op.execute('''CREATE UNIQUE INDEX chatbot_one_streaming_answer
        ON chatbot_messages(conversation_id)
        WHERE role = 'assistant' AND status = 'streaming' ''')


def downgrade():
    tables = ('chatbot_messages', 'chatbot_conversations')
    for table in tables:
        if op.get_bind().execute(text(f'SELECT EXISTS (SELECT 1 FROM {table})')).scalar():
            raise RuntimeError(f'Downgrade would delete chatbot data in {table}.')
    for table in tables:
        op.drop_table(table)
