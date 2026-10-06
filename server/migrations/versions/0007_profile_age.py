"""Store optional age on user profiles."""
from alembic import op

revision = '0007_profile_age'
down_revision = '0006_memory_albums'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('''ALTER TABLE users ADD COLUMN age SMALLINT
        CHECK (age BETWEEN 1 AND 120)''')


def downgrade():
    op.drop_column('users', 'age')
