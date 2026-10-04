"""Store account profile avatars."""
from alembic import op
from sqlalchemy import text

revision = '0004_avatar'
down_revision = '0003_couple'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''ALTER TABLE users ADD COLUMN avatar BYTEA
        CHECK (avatar IS NULL OR octet_length(avatar) <= 1048576)''')


def downgrade():
    if op.get_bind().execute(text(
            'SELECT EXISTS (SELECT 1 FROM users WHERE avatar IS NOT NULL)')).scalar():
        raise RuntimeError('Avatar downgrade would delete records; roll back the application instead.')
    op.drop_column('users', 'avatar')
