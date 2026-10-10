"""Add free-form daily expenses outside meals."""
from alembic import op
from sqlalchemy import text

revision = '0008_other_expenses'
down_revision = '0007_profile_age'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''CREATE TABLE other_expense_entries (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        date DATE NOT NULL,
        category TEXT NOT NULL CHECK (
            char_length(category) BETWEEN 1 AND 80 AND category ~ '[^[:space:]]'),
        expense_cents BIGINT NOT NULL CHECK (expense_cents BETWEEN 0 AND 10000000000)
    )''')
    op.execute('CREATE INDEX other_expense_entries_by_date ON other_expense_entries(user_id,date,id)')


def downgrade():
    if op.get_bind().execute(text('SELECT EXISTS (SELECT 1 FROM other_expense_entries)')).scalar():
        raise RuntimeError('Downgrade would delete other expense records; export them before rolling back.')
    op.drop_table('other_expense_entries')
