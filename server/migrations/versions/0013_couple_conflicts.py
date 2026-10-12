"""Add shared conflict reflections to couple spaces."""
from alembic import op
from sqlalchemy import text


revision = '0013_couple_conflicts'
down_revision = '0012_workout_actions'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE couple_conflicts (
        id BIGSERIAL PRIMARY KEY,
        space_id BIGINT NOT NULL REFERENCES couple_spaces(id) ON DELETE CASCADE,
        conflict_date DATE NOT NULL,
        title TEXT NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
        summary TEXT NOT NULL DEFAULT '' CHECK (length(summary) <= 3000),
        created_by BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'reflecting'
            CHECK (status IN ('reflecting', 'talking', 'agreed')),
        agreement TEXT NOT NULL DEFAULT '' CHECK (length(agreement) <= 2000),
        follow_up_date DATE,
        agreement_version INTEGER NOT NULL DEFAULT 0 CHECK (agreement_version >= 0),
        agreement_confirmed_by BIGINT[] NOT NULL DEFAULT '{}',
        client_request_id CHAR(32) NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        request_hash CHAR(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (created_by, client_request_id)
    )''')
    op.execute('''CREATE INDEX couple_conflicts_calendar
        ON couple_conflicts(space_id, conflict_date DESC, id DESC)''')
    op.execute('''CREATE TABLE couple_conflict_reflections (
        id BIGSERIAL PRIMARY KEY,
        conflict_id BIGINT NOT NULL REFERENCES couple_conflicts(id) ON DELETE CASCADE,
        author_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        observations TEXT NOT NULL DEFAULT '' CHECK (length(observations) <= 3000),
        feelings TEXT NOT NULL DEFAULT '' CHECK (length(feelings) <= 1000),
        needs TEXT NOT NULL DEFAULT '' CHECK (length(needs) <= 2000),
        my_part TEXT NOT NULL DEFAULT '' CHECK (length(my_part) <= 2000),
        request TEXT NOT NULL DEFAULT '' CHECK (length(request) <= 2000),
        published BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (conflict_id, author_id),
        CHECK (length(btrim(observations || feelings || needs || my_part || request)) > 0)
    )''')
    op.execute('''CREATE TABLE couple_conflict_comments (
        id BIGSERIAL PRIMARY KEY,
        conflict_id BIGINT NOT NULL REFERENCES couple_conflicts(id) ON DELETE CASCADE,
        author_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        content TEXT NOT NULL CHECK (length(btrim(content)) BETWEEN 1 AND 1000),
        client_request_id CHAR(32) NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (author_id, client_request_id)
    )''')
    op.execute('''CREATE INDEX couple_conflict_comments_order
        ON couple_conflict_comments(conflict_id, id)''')


def downgrade():
    if op.get_bind().execute(text(
            'SELECT EXISTS (SELECT 1 FROM couple_conflicts)')).scalar():
        raise RuntimeError(
            'Couple conflict downgrade would discard shared reflections.')
    op.drop_table('couple_conflict_comments')
    op.drop_table('couple_conflict_reflections')
    op.drop_index('couple_conflicts_calendar', table_name='couple_conflicts')
    op.drop_table('couple_conflicts')
