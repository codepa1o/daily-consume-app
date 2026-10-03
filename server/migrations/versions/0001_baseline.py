"""Create the 1.2.1 schema, or adopt an exactly matching existing database.

Revision ID: 0001_baseline
Revises: None
"""
import re
import secrets
from pathlib import Path

from alembic import context, op
from sqlalchemy import text

revision = '0001_baseline'
down_revision = None
branch_labels = None
depends_on = None

# Keep this snapshot immutable; subsequent changes belong in new revisions.
SCHEMA_SQL = Path(__file__).with_name('0001_schema.sql').read_text(encoding='utf-8')
TABLES = re.findall(r'CREATE TABLE (\w+)', SCHEMA_SQL)


def create_schema():
    # This fixed baseline contains plain DDL only, with no procedural SQL.
    for statement in SCHEMA_SQL.split(';'):
        if statement.strip():
            op.execute(statement.strip())


def snapshot(connection, schema):
    """Compare PostgreSQL's own normalized DDL, without reading business rows."""
    quoted = connection.dialect.identifier_preparer.quote_schema(schema)
    connection.exec_driver_sql(f'SET LOCAL search_path TO {quoted}')
    queries = {
        'columns': '''SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
            a.attnotnull, pg_get_expr(d.adbin, d.adrelid), a.attidentity, a.attgenerated,
            col.collname
            FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            JOIN pg_attribute a ON a.attrelid=c.oid
            LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
            LEFT JOIN pg_collation col ON col.oid=a.attcollation
            WHERE n.nspname=:schema AND c.relkind IN ('r','p')
                AND c.relname<>'alembic_version' AND a.attnum>0 AND NOT a.attisdropped
            ORDER BY c.relname, a.attnum''',
        'constraints': '''SELECT c.relname, con.conname,
            pg_get_constraintdef(con.oid), con.convalidated
            FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname=:schema AND c.relname<>'alembic_version'
            ORDER BY c.relname, con.conname''',
        'indexes': '''SELECT c.relname, idx.relname, pg_get_indexdef(i.indexrelid),
            i.indisvalid, i.indisready
            FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid
            JOIN pg_class idx ON idx.oid=i.indexrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname=:schema AND c.relname<>'alembic_version'
            ORDER BY c.relname, idx.relname''',
        'sequences': '''SELECT c.relname, format_type(s.seqtypid, NULL),
            s.seqstart, s.seqincrement, s.seqmax, s.seqmin, s.seqcache, s.seqcycle,
            owner.relname, a.attname
            FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid
            JOIN pg_namespace n ON n.oid=c.relnamespace
            LEFT JOIN pg_depend d ON d.objid=c.oid AND d.classid='pg_class'::regclass
                AND d.deptype='a'
            LEFT JOIN pg_class owner ON owner.oid=d.refobjid
            LEFT JOIN pg_attribute a ON a.attrelid=owner.oid AND a.attnum=d.refobjsubid
            WHERE n.nspname=:schema ORDER BY c.relname''',
    }
    result = {}
    for kind, query in queries.items():
        rows = [tuple(row) for row in connection.execute(text(query), {'schema': schema})]
        if kind == 'indexes':
            rows = [(table, name, ddl.replace(f' ON {quoted}.', ' ON '), valid, ready)
                    for table, name, ddl, valid, ready in rows]
        result[kind] = rows
    return result


def upgrade():
    if context.is_offline_mode():
        # Offline SQL initializes an empty database; adoption requires live inspection.
        create_schema()
        return

    connection = op.get_bind()
    schema = connection.scalar(text('SELECT current_schema()'))
    tables = set(connection.execute(text('''SELECT c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname=:schema AND c.relkind IN ('r','p','v','m','f')
            AND c.relname<>'alembic_version' '''), {'schema': schema}).scalars())
    if not tables:
        create_schema()
        return
    expected_tables = set(TABLES)
    if tables != expected_tables:
        raise RuntimeError('Baseline table mismatch; missing: '
                           f'{sorted(expected_tables - tables)}, unexpected: '
                           f'{sorted(tables - expected_tables)}. No baseline was adopted.')

    # Build a disposable reference in the same transaction and PostgreSQL version.
    # It is dropped on success and automatically rolled back on any failure.
    reference = 'alembic_baseline_' + secrets.token_hex(8)
    quote = connection.dialect.identifier_preparer.quote_schema
    connection.exec_driver_sql(f'CREATE SCHEMA {quote(reference)}')
    connection.exec_driver_sql(f'SET LOCAL search_path TO {quote(reference)}')
    create_schema()
    expected = snapshot(connection, reference)
    actual = snapshot(connection, schema)
    differences = []
    for kind in expected:
        if actual[kind] != expected[kind]:
            changed = set(actual[kind]) ^ set(expected[kind])
            differences.append(f'{kind}: {sorted({row[0] for row in changed})}')
    if differences:
        raise RuntimeError('Baseline structure mismatch (' + '; '.join(differences) +
                           '). Correct the schema before upgrading; do not stamp over differences.')
    connection.exec_driver_sql(f'DROP SCHEMA {quote(reference)} CASCADE')


def downgrade():
    # The baseline can adopt a live database. Never drop its business tables.
    raise RuntimeError('The baseline is irreversible: downgrading to base would delete '
                       'all business data. Restore a verified backup if necessary.')
