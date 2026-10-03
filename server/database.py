"""Shared PostgreSQL connection configuration for the API and Alembic."""
import os

DSN = os.environ.get('DATABASE_URL', 'dbname=daily_consume user=daily_consume host=/var/run/postgresql')
