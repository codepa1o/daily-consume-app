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
        if key not in {
            'DATABASE_URL', 'DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_MODEL',
            'AMAP_API_KEY', 'AMAP_MAPS_API_KEY', 'UNSPLASH_ACCESS_KEY',
            'LLM_API_KEY', 'LLM_BASE_URL', 'LLM_MODEL_ID', 'OPENAI_API_KEY',
            'OPENAI_BASE_URL', 'OPENAI_MODEL', 'USE_PERSONALIZED_PLANNER',
            'PERSONALIZED_LLM_API_KEY', 'PERSONALIZED_LLM_BASE_URL',
            'PERSONALIZED_LLM_MODEL_ID', 'PERSONALIZED_LLM_MODEL',
            'PERSONALIZED_LLM_PROVIDER', 'PLANNER_REQUEST_TIMEOUT',
            'PLANNER_ENABLE_RERANK', 'PLANNER_RERANK_CANDIDATE_COUNT',
            'PLANNER_CONTEXT_CACHE_DIR', 'PLANNER_FEEDBACK_ENABLED',
        }:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key, value)


load_project_env()
DSN = os.environ.get('DATABASE_URL') or 'dbname=daily_consume user=daily_consume host=/var/run/postgresql'
