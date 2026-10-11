"""Store optional exercise details on each workout log."""
from alembic import op
from sqlalchemy import text

revision = '0012_workout_actions'
down_revision = '0011_meal_items'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''ALTER TABLE workout_logs
        ADD COLUMN actions JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(actions) = 'array' AND jsonb_array_length(actions) <= 20)''')


def downgrade():
    if op.get_bind().execute(text(
            "SELECT EXISTS (SELECT 1 FROM workout_logs WHERE jsonb_array_length(actions) > 0)"
    )).scalar():
        raise RuntimeError(
            'Workout downgrade would discard recorded exercises.')
    op.drop_column('workout_logs', 'actions')
