"""Real HTTPS checks, no mocks. Test accounts are isolated and optionally removed."""
import argparse
import hashlib
import http.client
import json
import secrets
import socket
import ssl
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from zoneinfo import ZoneInfo


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-url', default='https://47.99.142.117/api/v1/')
    parser.add_argument('--ca', default=str(Path(__file__).resolve().parents[1] / 'assets/server_ca.pem'))
    parser.add_argument('--connect-host', help='Connect through a local tunnel while verifying the original IP certificate')
    parser.add_argument('--cleanup', action='store_true', help='Remove only the randomly generated test accounts using the local database')
    parser.add_argument('--report')
    args = parser.parse_args()
    origin = urlsplit(args.base_url)
    context = ssl.create_default_context(cafile=args.ca)
    passed = []
    prefix = 'api_check_' + secrets.token_hex(5)
    names = [prefix + '_a', prefix + '_b', prefix + '_c']
    password = secrets.token_urlsafe(18)
    tokens = {}

    def request(method, path, body=None, token=None, expected=200, query=None):
        connection = http.client.HTTPSConnection(origin.hostname, origin.port or 443, context=context, timeout=20)
        if args.connect_host:
            raw = socket.create_connection((args.connect_host, origin.port or 443), timeout=20)
            connection.sock = context.wrap_socket(raw, server_hostname=origin.hostname)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        url = origin.path.rstrip('/') + '/' + path
        if query:
            url += '?' + urlencode(query)
        try:
            connection.request(method, url, json.dumps(body, ensure_ascii=False).encode() if body is not None else None, headers)
            response = connection.getresponse()
            raw = response.read()
            try:
                data = json.loads(raw)
            except ValueError:
                data = None
            assert response.status == expected, f'{method} {path}: expected {expected}, got {response.status}: {data}'
            return data
        finally:
            connection.close()

    def ok(name):
        passed.append(name)
        print('PASS:', name, flush=True)

    def snapshot(tables):
        source = secrets.token_hex(32)
        raw = json.dumps(tables, ensure_ascii=False, separators=(',', ':'))
        return {'source_id': source, 'import_id': hashlib.sha256((source + raw).encode()).hexdigest(), 'tables': tables}

    try:
        assert request('GET', 'health')['status'] == 'ok'
        ok('TLS certificate and database health')
        for path in ['me', 'weights', 'heights', 'meals?start=2000-01-01&end=2000-01-02',
                     'workout/muscles', 'workout/plans', 'workout/settings', 'workout/logs?start=2000-01-01&end=2000-01-02']:
            request('GET', path, expected=401)
        request('POST', 'auth/logout', expected=401)
        request('POST', 'legacy/import', {'source_id': '0'*64, 'import_id': '0'*64, 'tables': {}}, expected=401)
        ok('All business endpoints require authentication')
        for name in names:
            result = request('POST', 'auth/register', {'username': name, 'password': password, 'nickname': '验证账号'}, expected=201)
            assert result['username'] == name and 'password_hash' not in result
            tokens[name] = request('POST', 'auth/login', {'username': name, 'password': password})['token']
        a, b = tokens[names[0]], tokens[names[1]]
        assert request('GET', 'me', token=a)['username'] == names[0]
        request('POST', 'auth/register', {'username': names[0].upper(), 'password': password}, expected=409)
        request('POST', 'auth/login', {'username': names[0], 'password': 'incorrect_password'}, expected=401)
        request('POST', 'auth/register', {'username': 'x', 'password': 'short'}, expected=422)
        ok('Registration, login, duplicate usernames and invalid credentials')
        request('PUT', 'weights', {'date': '2000-01-01', 'grams': 65000}, token=a)
        request('PUT', 'weights', {'date': '2000-01-01', 'grams': 72000}, token=b)
        request('PUT', 'heights', {'date': '2000-01-01', 'millimeters': 1750}, token=a)
        request('PUT', 'meals', {'date': '2000-01-01', 'meal_type': '午餐', 'foods': '米饭', 'expense_cents': 1800}, token=a)
        assert request('GET', 'weights', token=a)[0]['grams'] == 65000
        assert request('GET', 'weights', token=b)[0]['grams'] == 72000
        assert request('GET', 'heights', token=b) == []
        q = {'start': '2000-01-01', 'end': '2000-01-02'}
        assert request('GET', 'meals', token=b, query=q) == []
        request('DELETE', 'meals', token=b, query={'date': '2000-01-01', 'meal_type': '午餐'})
        assert request('GET', 'meals', token=a, query=q)[0]['expense_cents'] == 1800
        request('PUT', 'weights', {'user_id': 1, 'date': '2000-01-01', 'grams': 60000}, token=b, expected=422)
        ok('Account isolation for reads, writes and deletes')
        request('PUT', 'weights', {'date': '2000-01-01', 'grams': 1}, token=a, expected=422)
        request('PUT', 'meals', {'date': '2000-01-01', 'meal_type': '晚餐', 'foods': ' ', 'expense_cents': -1}, token=a, expected=422)
        request('GET', 'meals', token=a, query={'start': '2000-01-02', 'end': '2000-01-01'}, expected=422)
        ok('Server-side numeric, date and payload validation')
        defaults = request('GET', 'workout/muscles', token=a)
        assert len(defaults) == 5
        color = 0xffc87962
        request('POST', 'workout/muscles', {'name': '核心', 'color_value': color}, token=a, expected=201)
        plans = [{'weekday': day, 'muscles': ['核心'] if day == 1 else [], 'is_rest': 0} for day in range(1, 8)]
        request('PUT', 'workout/schedule', {'weekly_goal': 4, 'plans': plans}, token=a)
        assert request('GET', 'workout/settings', token=a)['weekly_goal'] == 4
        assert request('GET', 'workout/settings', token=b)['weekly_goal'] == 3
        today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
        request('POST', 'workout/logs', {'date': today, 'muscles': [{'name': '核心', 'color': color}]}, token=a, expected=201)
        request('POST', 'workout/logs', {'date': today, 'muscles': [{'name': '核心', 'color': color}]}, token=a, expected=409)
        request('PUT', 'workout/muscles', {'name': '核心', 'color_value': 1}, token=a)
        request('DELETE', 'workout/muscles', token=a, query={'name': '核心'})
        logs = request('GET', 'workout/logs', token=a, query={'start': today, 'end': today})
        assert logs[0]['muscles'][0]['color'] == color
        assert request('GET', 'workout/logs', token=b, query={'start': today, 'end': today}) == []
        assert request('GET', 'workout/plans', token=a)[0]['muscles'] == []
        request('DELETE', 'workout/logs', token=b, query={'date': today})
        assert len(request('GET', 'workout/logs', token=a, query={'start': today, 'end': today})) == 1
        rest = [{**plan, 'muscles': [], 'is_rest': 1} for plan in plans]
        request('PUT', 'workout/schedule', {'weekly_goal': 3, 'plans': rest}, token=b)
        request('POST', 'workout/logs', {'date': today, 'muscles': [{'name': '胸', 'color': color}]}, token=b, expected=409)
        invalid = [{**plan, 'weekday': 1} for plan in rest]
        request('PUT', 'workout/schedule', {'weekly_goal': 4, 'plans': invalid}, token=b, expected=422)
        assert request('GET', 'workout/settings', token=b)['weekly_goal'] == 3
        ok('Workout isolation, unique check-ins, rest days and historical colors')
        c = tokens[names[2]]
        old = snapshot({
            'weight_entries': [{'date': '2000-01-04', 'grams': 63000}],
            'height_entries': [{'date': '2000-01-04', 'millimeters': 1700}],
            'meal_entries': [{'date': '2000-01-04', 'meal_type': '晚餐', 'foods': '面条', 'expense_cents': 1500}],
            'workout_muscles': [{'name': name, 'color_value': value, 'built_in': 1} for name, value in
                                {'胸':0xffc87962,'背':0xff6d8fa4,'肩':0xffc59c4d,'腿':0xff718665,'手臂':0xff9b7ca0}.items()]
                               + [{'name':'核心','color_value':color,'built_in':0}],
            'workout_plans': [{'weekday':1,'muscles':'["核心"]','is_rest':0}],
            'workout_logs': [{'date':'2000-01-04','muscles':json.dumps([{'name':'核心','color':color}],ensure_ascii=False)}],
            'workout_settings': [{'id':1,'weekly_goal':5}],
        })
        full = request('POST', 'legacy/import', old, token=c)
        assert full['counts'] == {key:len(rows) for key,rows in old['tables'].items()}
        assert request('GET', 'workout/settings', token=c)['weekly_goal'] == 5
        assert request('GET', 'workout/plans', token=c)[0]['muscles'] == ['核心']
        assert request('GET', 'workout/logs', token=c, query={'start':'2000-01-04','end':'2000-01-04'})[0]['muscles'][0]['color'] == color
        request('PUT', 'weights', {'date':'2000-01-04','grams':64000}, token=c)
        request('POST', 'legacy/import', old, token=c, expected=409)
        ok('All seven legacy tables imported and receipt retries detect later changes')
        data = snapshot({'weight_entries': [{'date': '2000-01-02', 'grams': 66000}],
                         'meal_entries': [{'date': '2000-01-02', 'meal_type': '早餐', 'foods': '鸡蛋', 'expense_cents': 900}]})
        receipt = request('POST', 'legacy/import', data, token=a)
        assert receipt['import_id'] == data['import_id']
        assert receipt['counts'] == {'weight_entries': 1, 'meal_entries': 1}
        assert request('POST', 'legacy/import', data, token=a) == receipt
        request('POST', 'legacy/import', data, token=b, expected=409)
        assert len(request('GET', 'weights', token=a)) == 2
        ok('Legacy import receipts, idempotency and account ownership')
        conflict = snapshot({'weight_entries': [{'date': '2000-01-03', 'grams': 67000}, {'date': '2000-01-01', 'grams': 99000}]})
        request('POST', 'legacy/import', conflict, token=a, expected=409)
        assert len(request('GET', 'weights', token=a)) == 2
        assert request('GET', 'weights', token=a)[0]['grams'] == 65000
        tampered = {**data, 'import_id': '0'*64}
        request('POST', 'legacy/import', tampered, token=a, expected=422)
        ok('Import conflicts roll back the entire transaction')
        request('POST', 'auth/logout', token=a)
        request('GET', 'me', token=a, expected=401)
        new = request('POST', 'auth/login', {'username': names[0], 'password': password})['token']
        assert len(request('GET', 'weights', token=new)) == 2
        request('POST', 'auth/logout', token=new)
        request('POST', 'auth/logout', token=b)
        request('POST', 'auth/logout', token=c)
        ok('Logout revocation and data retained after signing in again')
        if args.cleanup:
            import psycopg
            from app import DSN
            expired = request('POST', 'auth/login', {'username': names[2], 'password': password})['token']
            with psycopg.connect(DSN) as db:
                db.execute('UPDATE user_sessions SET expires_at=now()-interval \'1 second\' WHERE token_hash=%s',
                           (hashlib.sha256(expired.encode()).hexdigest(),))
            request('GET', 'me', token=expired, expected=401)
            request('GET', 'weights', token=expired, expected=401)
            ok('Expired sessions cannot read identity or business records')
        result = {'passed': len(passed), 'checks': passed, 'base_url': args.base_url, 'test_accounts': names}
        if args.report:
            Path(args.report).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'{len(passed)} real API checks passed.')
    finally:
        if args.cleanup:
            import psycopg
            from app import DSN
            with psycopg.connect(DSN) as db:
                db.execute('DELETE FROM users WHERE username=ANY(%s)', (names,))
            print('Generated test accounts removed.', flush=True)


if __name__ == '__main__':
    main()
