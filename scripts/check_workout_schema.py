"""Compatibility entry: workout storage now uses the real server API."""
import runpy
from pathlib import Path

if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).resolve().parents[1] / 'server/check_api.py'), run_name='__main__')
