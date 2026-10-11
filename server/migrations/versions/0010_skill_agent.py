"""新增按账号隔离的 Skill Agent 对话、知识库和评测数据。"""
from alembic import op
from sqlalchemy import text

revision = '0010_skill_agent'
down_revision = '0009_body_weight_goal'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE skill_agent_conversations (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 80),
        skill_url TEXT NOT NULL,
        raw_url TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT '',
        api_mode TEXT NOT NULL DEFAULT '',
        base_url TEXT NOT NULL DEFAULT '',
        reasoning_effort TEXT NOT NULL DEFAULT '',
        memory_summary TEXT NOT NULL DEFAULT '',
        memory_last_message_id BIGINT NOT NULL DEFAULT 0,
        memory_updated_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (id, user_id)
    )''')
    op.execute('''CREATE INDEX skill_agent_conversations_recent
        ON skill_agent_conversations(user_id, updated_at DESC, id DESC)''')

    op.execute('''CREATE TABLE skill_agent_messages (
        id BIGSERIAL PRIMARY KEY,
        conversation_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
        content TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'complete'
            CHECK (status IN ('streaming', 'complete', 'failed')),
        latency_ms INTEGER NOT NULL DEFAULT 0 CHECK (latency_ms >= 0),
        error_message TEXT NOT NULL DEFAULT '',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        FOREIGN KEY (conversation_id, user_id)
            REFERENCES skill_agent_conversations(id, user_id) ON DELETE CASCADE,
        UNIQUE (id, conversation_id, user_id)
    )''')
    op.execute('''CREATE INDEX skill_agent_messages_order
        ON skill_agent_messages(user_id, conversation_id, id)''')

    op.execute('''CREATE TABLE skill_agent_runs (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        conversation_id BIGINT,
        skill_url TEXT NOT NULL,
        raw_url TEXT NOT NULL DEFAULT '',
        question TEXT NOT NULL,
        answer TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        api_mode TEXT NOT NULL DEFAULT '',
        base_url TEXT NOT NULL DEFAULT '',
        reasoning_effort TEXT NOT NULL DEFAULT '',
        search_used BOOLEAN NOT NULL DEFAULT FALSE,
        search_results JSONB NOT NULL DEFAULT '[]'::jsonb,
        rag_used BOOLEAN NOT NULL DEFAULT FALSE,
        rag_results JSONB NOT NULL DEFAULT '[]'::jsonb,
        status TEXT NOT NULL CHECK (status IN ('running', 'success', 'failed')),
        error_message TEXT NOT NULL DEFAULT '',
        latency_ms INTEGER NOT NULL DEFAULT 0 CHECK (latency_ms >= 0),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        FOREIGN KEY (conversation_id, user_id)
            REFERENCES skill_agent_conversations(id, user_id) ON DELETE CASCADE
    )''')
    op.execute('CREATE INDEX skill_agent_runs_recent ON skill_agent_runs(user_id, created_at DESC, id DESC)')

    op.execute('''CREATE TABLE skill_agent_documents (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        filename TEXT NOT NULL CHECK (char_length(filename) BETWEEN 1 AND 255),
        file_type TEXT NOT NULL CHECK (file_type IN ('md', 'markdown', 'txt', 'pdf')),
        content BYTEA NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('queued', 'indexing', 'ready', 'failed')),
        error_message TEXT NOT NULL DEFAULT '',
        chunk_count INTEGER NOT NULL DEFAULT 0 CHECK (chunk_count >= 0),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (id, user_id)
    )''')
    op.execute('CREATE INDEX skill_agent_documents_recent ON skill_agent_documents(user_id, created_at DESC, id DESC)')

    op.execute('''CREATE TABLE skill_agent_chunks (
        id BIGSERIAL PRIMARY KEY,
        document_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
        page_number INTEGER NOT NULL DEFAULT 0 CHECK (page_number >= 0),
        content TEXT NOT NULL,
        embedding JSONB NOT NULL,
        embedding_dim INTEGER NOT NULL CHECK (embedding_dim > 0),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        FOREIGN KEY (document_id, user_id)
            REFERENCES skill_agent_documents(id, user_id) ON DELETE CASCADE,
        UNIQUE (document_id, chunk_index)
    )''')
    op.execute('CREATE INDEX skill_agent_chunks_by_document ON skill_agent_chunks(user_id, document_id, chunk_index)')

    op.execute('''CREATE TABLE skill_agent_test_suites (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
        skill_url TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        is_template BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (id, user_id)
    )''')
    op.execute('CREATE INDEX skill_agent_suites_recent ON skill_agent_test_suites(user_id, created_at DESC, id DESC)')
    op.execute('''CREATE UNIQUE INDEX skill_agent_one_template_per_user
        ON skill_agent_test_suites(user_id) WHERE is_template''')

    op.execute('''CREATE TABLE skill_agent_test_cases (
        id BIGSERIAL PRIMARY KEY,
        suite_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120),
        question TEXT NOT NULL CHECK (char_length(question) BETWEEN 1 AND 12000),
        expected_behavior TEXT NOT NULL CHECK (char_length(expected_behavior) BETWEEN 1 AND 6000),
        scoring_focus TEXT NOT NULL CHECK (char_length(scoring_focus) BETWEEN 1 AND 6000),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        FOREIGN KEY (suite_id, user_id)
            REFERENCES skill_agent_test_suites(id, user_id) ON DELETE CASCADE,
        UNIQUE (id, user_id)
    )''')
    op.execute('CREATE INDEX skill_agent_cases_by_suite ON skill_agent_test_cases(user_id, suite_id, id)')

    op.execute('''CREATE TABLE skill_agent_eval_runs (
        id BIGSERIAL PRIMARY KEY,
        suite_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
        average_score NUMERIC(4, 2) NOT NULL DEFAULT 0 CHECK (average_score BETWEEN 0 AND 5),
        error_message TEXT NOT NULL DEFAULT '',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        finished_at TIMESTAMPTZ,
        FOREIGN KEY (suite_id, user_id)
            REFERENCES skill_agent_test_suites(id, user_id) ON DELETE CASCADE,
        UNIQUE (id, user_id)
    )''')
    op.execute('CREATE INDEX skill_agent_eval_runs_recent ON skill_agent_eval_runs(user_id, created_at DESC, id DESC)')

    op.execute('''CREATE TABLE skill_agent_eval_results (
        id BIGSERIAL PRIMARY KEY,
        eval_run_id BIGINT NOT NULL,
        test_case_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        variant TEXT NOT NULL CHECK (variant IN ('baseline', 'enhanced')),
        agent_answer TEXT NOT NULL DEFAULT '',
        role_adherence SMALLINT NOT NULL DEFAULT 0 CHECK (role_adherence BETWEEN 0 AND 5),
        constraint_adherence SMALLINT NOT NULL DEFAULT 0 CHECK (constraint_adherence BETWEEN 0 AND 5),
        task_completion SMALLINT NOT NULL DEFAULT 0 CHECK (task_completion BETWEEN 0 AND 5),
        factual_safety SMALLINT NOT NULL DEFAULT 0 CHECK (factual_safety BETWEEN 0 AND 5),
        format_quality SMALLINT NOT NULL DEFAULT 0 CHECK (format_quality BETWEEN 0 AND 5),
        source_usage SMALLINT NOT NULL DEFAULT 0 CHECK (source_usage BETWEEN 0 AND 5),
        overall NUMERIC(4, 2) NOT NULL DEFAULT 0 CHECK (overall BETWEEN 0 AND 5),
        judge_comment TEXT NOT NULL DEFAULT '',
        search_used BOOLEAN NOT NULL DEFAULT FALSE,
        search_results JSONB NOT NULL DEFAULT '[]'::jsonb,
        rag_used BOOLEAN NOT NULL DEFAULT FALSE,
        rag_results JSONB NOT NULL DEFAULT '[]'::jsonb,
        error_message TEXT NOT NULL DEFAULT '',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        FOREIGN KEY (eval_run_id, user_id)
            REFERENCES skill_agent_eval_runs(id, user_id) ON DELETE CASCADE,
        FOREIGN KEY (test_case_id, user_id)
            REFERENCES skill_agent_test_cases(id, user_id) ON DELETE CASCADE,
        UNIQUE (eval_run_id, test_case_id, variant)
    )''')
    op.execute('CREATE INDEX skill_agent_eval_results_by_run ON skill_agent_eval_results(user_id, eval_run_id, test_case_id)')

    op.execute('''CREATE TABLE skill_agent_jobs (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        type TEXT NOT NULL CHECK (type IN ('index_document', 'run_eval_suite')),
        status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
        payload JSONB NOT NULL DEFAULT '{}'::jsonb,
        result JSONB NOT NULL DEFAULT '{}'::jsonb,
        error_message TEXT NOT NULL DEFAULT '',
        attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        started_at TIMESTAMPTZ,
        finished_at TIMESTAMPTZ
    )''')
    op.execute('CREATE INDEX skill_agent_jobs_queue ON skill_agent_jobs(status, created_at, id)')
    op.execute('CREATE INDEX skill_agent_jobs_by_owner ON skill_agent_jobs(user_id, id)')


def downgrade():
    tables = (
        'skill_agent_jobs', 'skill_agent_eval_results', 'skill_agent_eval_runs',
        'skill_agent_test_cases', 'skill_agent_test_suites', 'skill_agent_chunks',
        'skill_agent_documents', 'skill_agent_runs', 'skill_agent_messages',
        'skill_agent_conversations',
    )
    for table in tables:
        if op.get_bind().execute(text(f'SELECT EXISTS (SELECT 1 FROM {table})')).scalar():
            raise RuntimeError(f'Downgrade would delete Skill Agent data in {table}.')
    for table in tables:
        op.drop_table(table)
