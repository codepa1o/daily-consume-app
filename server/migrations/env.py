"""Run migrations using the same libpq DSN and psycopg driver as the API."""
import logging

import psycopg
from alembic import context
from sqlalchemy import create_engine, text
from sqlalchemy.pool import NullPool

from database import DSN

logger = logging.getLogger('alembic')
logger.setLevel(logging.INFO)
logger.propagate = False
if not logger.handlers:
    logger.addHandler(logging.StreamHandler())
config = context.config

# There is no SQLAlchemy model metadata: revisions are written by hand.
if getattr(config.cmd_opts, 'autogenerate', False):
    raise RuntimeError('This project uses handwritten migrations; omit --autogenerate.')

if context.is_offline_mode():
    context.configure(url='postgresql+psycopg://', literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    dsn = config.attributes.get('database_url', DSN)
    engine = create_engine('postgresql+psycopg://', creator=lambda: psycopg.connect(dsn),
                           poolclass=NullPool, hide_parameters=True)
    with engine.connect() as connection, connection.begin():
        schema = connection.scalar(text('SELECT current_schema()'))
        if not schema:
            raise RuntimeError('DATABASE_URL search_path must select an existing schema.')
        # Serialize commands before Alembic reads or creates its version table.
        connection.execute(text('SELECT pg_advisory_xact_lock(hashtext(current_database()), '
                                'hashtext(:schema))'), {'schema': schema})
        context.configure(connection=connection, target_metadata=None,
                          version_table_schema=schema)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
