"""Shared PostgreSQL connection configuration for the API and Alembic."""
import os
from pathlib import Path


def load_project_env():
    env_file = Path(__file__).resolve().parents[1] / '.env'
    try:
        lines = env_file.read_text(encoding='utf-8').splitlines()
    except FileNotFoundError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key, value = key.strip(), value.strip()
        if key not in {'DATABASE_URL', 'DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_MODEL'}:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key, value)


load_project_env()
DSN = os.environ.get('DATABASE_URL') or 'dbname=daily_consume user=daily_consume host=/var/run/postgresql'
