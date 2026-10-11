"""Persist the food names and expenses within each meal."""
from alembic import op
from sqlalchemy import text

revision = '0011_meal_items'
down_revision = '0010_skill_agent'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''ALTER TABLE meal_entries
        ADD COLUMN items JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(items) = 'array' AND jsonb_array_length(items) <= 20)''')


def downgrade():
    if op.get_bind().execute(text(
            "SELECT EXISTS (SELECT 1 FROM meal_entries WHERE jsonb_array_length(items) > 0)"
    )).scalar():
        raise RuntimeError(
            'Meal item downgrade would discard per-item names and amounts.')
    op.drop_column('meal_entries', 'items')
