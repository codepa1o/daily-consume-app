"""Store ordered multi-photo couple memories and their display mode."""
from alembic import op
from sqlalchemy import text

revision = '0006_memory_albums'
down_revision = '0005_pomodoro'
branch_labels = None
depends_on = None


def upgrade():
    op.execute("""ALTER TABLE couple_memories ADD COLUMN display_mode TEXT NOT NULL DEFAULT 'grid'
        CHECK (display_mode IN ('grid','swipe'))""")
    op.execute('''CREATE TABLE couple_memory_photos (
        id BIGSERIAL PRIMARY KEY,
        memory_id BIGINT NOT NULL REFERENCES couple_memories(id) ON DELETE CASCADE,
        position SMALLINT NOT NULL CHECK (position BETWEEN 0 AND 8),
        photo BYTEA NOT NULL CHECK (octet_length(photo) <= 8388608),
        thumbnail BYTEA NOT NULL CHECK (octet_length(thumbnail) <= 1048576),
        UNIQUE(memory_id, position)
    )''')
    op.execute('CREATE INDEX couple_memory_photos_order ON couple_memory_photos(memory_id,position)')
    op.execute('''INSERT INTO couple_memory_photos(memory_id,position,photo,thumbnail)
        SELECT id,0,photo,thumbnail FROM couple_memories WHERE photo IS NOT NULL''')


def downgrade():
    if op.get_bind().execute(text('''SELECT EXISTS(
        SELECT 1 FROM couple_memories m
        WHERE m.display_mode <> 'grid'
           OR (SELECT count(*) FROM couple_memory_photos p WHERE p.memory_id=m.id)>1)''')).scalar():
        raise RuntimeError('Album downgrade would delete records (photos or display choices); roll back the application instead.')
    op.execute('''UPDATE couple_memories m SET photo=p.photo,thumbnail=p.thumbnail
        FROM couple_memory_photos p WHERE p.memory_id=m.id AND p.position=0''')
    op.drop_table('couple_memory_photos')
    op.drop_column('couple_memories', 'display_mode')
