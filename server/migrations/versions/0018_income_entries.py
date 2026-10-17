"""新增账号隔离的收入明细，不修改已有餐食与支出记录。"""
from alembic import op
from sqlalchemy import text

revision = '0018_income_entries'
down_revision = '0017_couple_comment_interactions'
branch_labels = None
depends_on = None


def upgrade():
    # 分为金额最小单位，同一账号的创建请求编号唯一，保证重复发送不重复入账。
    op.execute('''CREATE TABLE income_entries (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        date DATE NOT NULL CHECK (date >= DATE '2000-01-01'),
        category TEXT NOT NULL CHECK (
            char_length(category) BETWEEN 1 AND 80 AND category ~ '[^[:space:]]'),
        income_cents BIGINT NOT NULL CHECK (income_cents BETWEEN 1 AND 10000000000),
        notes TEXT NOT NULL DEFAULT '' CHECK (char_length(notes) <= 1000),
        client_request_id TEXT NOT NULL CHECK (client_request_id ~ '^[a-f0-9]{32}$'),
        request_hash TEXT NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE(user_id,client_request_id)
    )''')
    op.execute('CREATE INDEX income_entries_by_date ON income_entries(user_id,date,id)')


def downgrade():
    # 有收入记录时不自动删除，回滚应用代码可以保留此新增表。
    if op.get_bind().execute(text('SELECT EXISTS(SELECT 1 FROM income_entries)')).scalar():
        raise RuntimeError('Downgrade would delete income records; export them before rolling back.')
    op.drop_table('income_entries')
