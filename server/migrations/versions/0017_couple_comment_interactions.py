"""为回忆与反思评论补充两级回复和账号唯一点赞。"""
from alembic import op
from sqlalchemy import text

revision = '0017_couple_comment_interactions'
down_revision = '0016_pomodoro_reminders'
branch_labels = None
depends_on = None


def upgrade():
    # 原评论均保持为主评论；组合外键阻止回复引用另一段回忆或另一条反思。
    for table, scope in (('couple_comments', 'memory_id'),
                         ('couple_conflict_comments', 'conflict_id')):
        op.execute(f'ALTER TABLE {table} ADD COLUMN parent_id BIGINT, ADD COLUMN reply_to_id BIGINT')
        op.execute(f'ALTER TABLE {table} ADD CONSTRAINT {table}_scope_unique UNIQUE(id,{scope})')
        for column in ('parent_id', 'reply_to_id'):
            op.execute(f'''ALTER TABLE {table} ADD CONSTRAINT {table}_{column}_fk
                FOREIGN KEY ({column},{scope}) REFERENCES {table}(id,{scope}) ON DELETE CASCADE''')
        op.execute(f'''ALTER TABLE {table} ADD CONSTRAINT {table}_reply_pair
            CHECK ((parent_id IS NULL) = (reply_to_id IS NULL)
                AND parent_id IS DISTINCT FROM id AND reply_to_id IS DISTINCT FROM id)''')
        op.execute(f'CREATE INDEX {table}_thread ON {table}({scope},parent_id,id)')
    op.execute('''CREATE TABLE couple_comment_likes (
        comment_id BIGINT NOT NULL REFERENCES couple_comments(id) ON DELETE CASCADE,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY(comment_id,user_id)
    )''')
    op.execute('''CREATE TABLE couple_conflict_comment_likes (
        comment_id BIGINT NOT NULL REFERENCES couple_conflict_comments(id) ON DELETE CASCADE,
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY(comment_id,user_id)
    )''')


def downgrade():
    # 有互动数据时拒绝回退，以免在回滚代码时静默丢失回复或点赞。
    for table in ('couple_comment_likes', 'couple_conflict_comment_likes'):
        if op.get_bind().execute(text(f'SELECT EXISTS(SELECT 1 FROM {table})')).scalar():
            raise RuntimeError('Downgrade would discard comment likes.')
    for table in ('couple_comments', 'couple_conflict_comments'):
        if op.get_bind().execute(text(f'SELECT EXISTS(SELECT 1 FROM {table} WHERE parent_id IS NOT NULL)')).scalar():
            raise RuntimeError('Downgrade would discard comment replies.')
    op.drop_table('couple_conflict_comment_likes')
    op.drop_table('couple_comment_likes')
    for table in ('couple_comments', 'couple_conflict_comments'):
        op.drop_index(f'{table}_thread', table_name=table)
        for column in ('parent_id', 'reply_to_id'):
            op.drop_constraint(f'{table}_{column}_fk', table_name=table)
        op.drop_constraint(f'{table}_reply_pair', table_name=table)
        op.drop_constraint(f'{table}_scope_unique', table_name=table)
        op.drop_column(table, 'reply_to_id')
        op.drop_column(table, 'parent_id')
