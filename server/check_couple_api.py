"""Real Nginx HTTPS and PostgreSQL checks using disposable, private test accounts."""
import argparse
import base64
import http.client
import io
import json
import secrets
import socket
import ssl
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

from PIL import Image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-url', default='https://47.99.142.117/api/v1/')
    parser.add_argument('--ca', default=str(Path(__file__).resolve().parents[1] / 'assets/server_ca.pem'))
    parser.add_argument('--connect-host')
    parser.add_argument('--report')
    args = parser.parse_args()
    origin = urlsplit(args.base_url)
    context = ssl.create_default_context(cafile=args.ca)
    users, tokens, checks = [], [], []

    def request(method, path, body=None, token=None, expected=200, binary=False):
        connection = http.client.HTTPSConnection(origin.hostname, origin.port or 443, context=context, timeout=30)
        if args.connect_host:
            raw = socket.create_connection((args.connect_host, origin.port or 443), timeout=30)
            connection.sock = context.wrap_socket(raw, server_hostname=origin.hostname)
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        try:
            connection.request(method, origin.path.rstrip('/') + '/' + path,
                               None if body is None else json.dumps(body).encode(), headers)
            response = connection.getresponse()
            raw = response.read()
            assert response.status == expected, f'{method} {path}: expected {expected}, received {response.status}'
            if binary:
                assert response.getheader('Cache-Control') == 'no-store'
                assert response.getheader('Content-Type') == 'image/jpeg'
                return raw
            return json.loads(raw)
        finally:
            connection.close()

    def passed(name):
        checks.append(name)
        print('PASS:', name, flush=True)

    try:
        request('GET', 'couple/space', expected=401)
        for suffix in ('a', 'b', 'c'):
            credentials = {'username': 'couple_check_' + secrets.token_hex(5) + suffix,
                           'password': secrets.token_urlsafe(24)}
            user = request('POST', 'auth/register', credentials, expected=201)
            users.append((user['id'], user['username']))
            tokens.append(request('POST', 'auth/login', credentials)['token'])
        a, b, outsider = tokens
        assert request('GET', 'couple/space', token=a) is None
        request('POST', 'couple/space', {'title': 'HTTPS verification', 'since_date': '2024-02-29'}, a, 201)
        code = request('POST', 'couple/invite', token=a)['code']
        request('POST', 'couple/invite/preview', {'code': code}, b)
        assert request('GET', 'couple/space', token=b) is None
        request('POST', 'couple/join', {'code': code}, b)
        assert len(request('GET', 'couple/space', token=b)['members']) == 2
        request('POST', 'couple/join', {'code': code}, outsider, 404)
        passed('TLS, authenticated invitation confirmation, shared space and one-time code')
        anniversary = request('PUT', 'couple/space/anniversary',
                              {'since_date': '2024-02-28'}, a)
        assert anniversary['since_date'] == '2024-02-28'
        assert request('GET', 'couple/space', token=b)['since_date'] == '2024-02-28'
        passed('Calendar anniversary updates are shared with both members')
        output = io.BytesIO()
        Image.new('RGB', (320, 220), '#b68370').save(output, 'JPEG')
        body = {'memory_date': '2024-02-29', 'title': 'Test memory', 'content': 'HTTPS test',
                'mood': '开心', 'photo_base64': base64.b64encode(output.getvalue()).decode(),
                'client_request_id': secrets.token_hex(16)}
        first = request('POST', 'couple/memories', body, a, 201)
        repeated = request('POST', 'couple/memories', body, a, 201)
        assert first['id'] == repeated['id']
        ident = first['id']
        Image.open(io.BytesIO(request('GET', f'couple/memories/{ident}/photo?thumbnail=false', token=b, binary=True))).verify()
        request('GET', f'couple/memories/{ident}/photo', token=outsider, expected=404)
        request('GET', f'couple/memories/{ident}', token=outsider, expected=404)
        passed('Photo upload, safe retry, JPEG read, no-store and outsider denial')
        album_body = {key: value for key, value in body.items() if key != 'photo_base64'}
        album_body |= {'display_mode': 'swipe', 'photos_base64': [body['photo_base64']] * 2,
                       'client_request_id': secrets.token_hex(16)}
        album = request('POST', 'couple/memories', album_body, a, 201)
        assert album['photo_count'] == 2 and album['display_mode'] == 'swipe'
        thumbnails = request('GET', f"couple/memories/{album['id']}/photos", token=b)['items']
        assert [item['position'] for item in thumbnails] == [0, 1]
        for position in range(2):
            Image.open(io.BytesIO(request('GET',
                f"couple/memories/{album['id']}/photos/{position}?thumbnail=false",
                token=b, binary=True))).verify()
        request('GET', f"couple/memories/{album['id']}/photos/0", token=outsider, expected=404)
        nine_body = album_body | {'display_mode': 'grid', 'photos_base64': [body['photo_base64']] * 9,
                                  'client_request_id': secrets.token_hex(16)}
        nine = request('POST', 'couple/memories', nine_body, a, 201)
        assert nine['photo_count'] == 9 and nine['display_mode'] == 'grid'
        thumbs = request('GET', f"couple/memories/{nine['id']}/photos", token=b)['items']
        assert [item['position'] for item in thumbs] == list(range(9))
        cover = Image.open(io.BytesIO(request('GET',
            f"couple/memories/{nine['id']}/photo?thumbnail=true", token=b, binary=True)))
        assert cover.size == (400, 400)
        request('POST', 'couple/memories',
                nine_body | {'photos_base64': [body['photo_base64']] * 10,
                             'client_request_id': secrets.token_hex(16)}, a, 422)
        passed('Two-photo swipe and nine-photo grid albums, order, cap and access checks')
        request('POST', 'couple/memories', body | {'client_request_id': secrets.token_hex(16)}, b, 201)
        published_today = datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat()
        assert len(request('GET', 'couple/pair?date=' + published_today, token=a)['items']) == 2
        request('POST', f'couple/memories/{ident}/comments',
                {'content': 'A note for you', 'client_request_id': secrets.token_hex(16)}, b, 201)
        request('PUT', f'couple/memories/{ident}/reaction', {'emoji': '❤️'}, b)
        detail = request('GET', f'couple/memories/{ident}', token=a)
        assert len(detail['comments']) == len(detail['reactions']) == 1
        request('DELETE', f'couple/memories/{ident}', token=b, expected=403)
        request('DELETE', f'couple/memories/{ident}', token=a)
        request('GET', f'couple/memories/{ident}/photo', token=b, expected=404)
        passed('Two-author collage, partner comments, reactions and author-only deletion')
        conflict = request('POST', 'couple/conflicts', {
            'conflict_date': published_today, 'title': 'HTTPS reflection check',
            'summary': 'Disposable release verification',
            'client_request_id': secrets.token_hex(16)}, a, 201)
        path = f"couple/conflicts/{conflict['id']}"
        reflection = {'observations': 'We had different plans', 'feelings': 'Calmer now',
                      'needs': 'Plan together', 'my_part': 'Ask earlier',
                      'request': 'Agree on a time', 'published': False}
        request('PUT', path + '/reflection', reflection, a)
        assert request('GET', path, token=b)['reflections'] == []
        request('GET', path, token=outsider, expected=404)
        for token in (a, b):
            request('PUT', path + '/reflection', reflection | {'published': True}, token)
        agreement = {'agreement': 'Confirm plans together', 'expected_version': 0,
                     'follow_up_date': published_today}
        first = request('PUT', path + '/agreement', agreement, a)
        assert first['status'] == 'talking'
        request('PUT', path + '/agreement', agreement, b, 409)
        agreed = request('PUT', path + '/agreement',
                         agreement | {'expected_version': first['agreement_version']}, b)
        assert agreed['status'] == 'agreed'
        assert set(agreed['agreement_confirmed_by']) == {users[0][0], users[1][0]}
        comment = {'content': 'Understood', 'client_request_id': secrets.token_hex(16)}
        request('POST', path + '/comments', comment, b, 201)
        assert len(request('GET', path, token=a)['comments']) == 1
        calendar = request('GET', f'couple/conflicts?start={published_today}&end={published_today}', token=b)
        assert any(row['id'] == conflict['id'] for row in calendar)
        request('DELETE', path, token=b, expected=403)
        request('DELETE', path, token=a)
        request('GET', path, token=b, expected=404)
        passed('Conflict calendar, private draft, comments, two-member agreement and stale-version protection')
        request('POST', 'journal/entries', {'entry_date': '2024-02-29', 'kind': 'diary',
            'content': 'Compatibility test', 'client_request_id': secrets.token_hex(16)}, a, 201)
        assert request('GET', 'journal/entries?date=2024-02-29', token=a)['total'] == 1
        assert request('GET', 'journal/entries?date=2024-02-29', token=b)['total'] == 0
        passed('Shared album does not expose account-private life calendar')
    finally:
        if users:
            import psycopg
            from database import DSN
            with psycopg.connect(DSN) as db:
                ids = [user[0] for user in users]
                db.execute('DELETE FROM couple_spaces WHERE created_by=ANY(%s)', (ids,))
                for ident, name in users:
                    db.execute('DELETE FROM users WHERE id=%s AND username=%s', (ident, name))
            passed('Only this run\'s disposable accounts and spaces removed')
    if args.report:
        Path(args.report).write_text(json.dumps({'passed': len(checks), 'checks': checks}, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
