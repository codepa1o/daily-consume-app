"""将微信小程序身份绑定到现有账号。"""
from alembic import op
from sqlalchemy import text


revision = '0015_wechat_identity'
down_revision = '0014_chatbot'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE wechat_identities (
        app_id TEXT NOT NULL,
        openid TEXT NOT NULL,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (app_id, openid),
        UNIQUE (app_id, user_id)
    )''')


def downgrade():
    if op.get_bind().execute(text(
            'SELECT EXISTS (SELECT 1 FROM wechat_identities)')).scalar():
        raise RuntimeError('Downgrade would delete linked WeChat identities.')
    op.drop_table('wechat_identities')
