"""Store an optional account body-weight goal."""
from alembic import op
from sqlalchemy import text

revision = '0009_body_weight_goal'
down_revision = '0008_other_expenses'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE body_settings (
        user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        goal_weight_grams INTEGER CHECK (goal_weight_grams BETWEEN 20000 AND 300000)
    )''')


def downgrade():
    if op.get_bind().execute(text(
            'SELECT EXISTS (SELECT 1 FROM body_settings WHERE goal_weight_grams IS NOT NULL)')).scalar():
        raise RuntimeError(
            'Body goal downgrade would delete saved goals; roll back the application instead.')
    op.drop_table('body_settings')
