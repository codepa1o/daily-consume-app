"""将本地 Flutter Web 调试请求安全转发到已部署的日常 API。"""
from http.client import HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl
from urllib.parse import urlsplit


API_HOST = '47.99.142.117'
API_PREFIX = '/api/v1'
CA_FILE = Path(__file__).resolve().parents[1] / 'assets' / 'server_ca.pem'
ALLOWED_ORIGINS = {
    'http://127.0.0.1:8080',
    'http://localhost:8080',
}
ALLOWED_METHODS = {'GET', 'POST', 'PUT', 'DELETE'}
ALLOWED_HEADERS = {'accept', 'authorization', 'content-type'}
MAX_BODY_BYTES = 20 * 1024 * 1024
TLS_CONTEXT = ssl.create_default_context(cafile=str(CA_FILE))


class WebApiProxy(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_OPTIONS(self):
        origin = self.headers.get('Origin')
        method = self.headers.get('Access-Control-Request-Method', '').upper()
        headers = {
            value.strip().lower()
            for value in self.headers.get('Access-Control-Request-Headers', '').split(',')
            if value.strip()
        }
        if origin not in ALLOWED_ORIGINS or method not in ALLOWED_METHODS:
            self.send_error(403, '浏览器来源或请求方法不允许')
            return
        if not headers.issubset(ALLOWED_HEADERS):
            self.send_error(403, '浏览器请求头不允许')
            return

        self.send_response(204)
        self._add_cors_headers(origin)
        self.send_header('Access-Control-Allow-Methods', ', '.join(sorted(ALLOWED_METHODS)))
        self.send_header('Access-Control-Allow-Headers', 'Accept, Authorization, Content-Type')
        self.send_header('Access-Control-Max-Age', '600')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def _proxy(self):
        origin = self.headers.get('Origin')
        if origin is not None and origin not in ALLOWED_ORIGINS:
            self.send_error(403, '浏览器来源不允许')
            return

        target = urlsplit(self.path)
        if target.scheme or target.netloc or not target.path.startswith('/') or target.path.startswith('//'):
            self.send_error(400, '请求路径无效')
            return

        try:
            content_length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self.send_error(400, '请求长度无效')
            return
        if content_length < 0 or content_length > MAX_BODY_BYTES:
            self.send_error(413, '请求内容过大')
            return

        body = self.rfile.read(content_length) if content_length else None
        request_headers = {
            name: self.headers[name]
            for name in ('Accept', 'Authorization', 'Content-Type')
            if name in self.headers
        }
        target_path = API_PREFIX + target.path
        if target.query:
            target_path += '?' + target.query

        connection = HTTPSConnection(API_HOST, context=TLS_CONTEXT, timeout=30)
        try:
            connection.request(self.command, target_path, body=body, headers=request_headers)
            upstream = connection.getresponse()
            response_body = upstream.read(MAX_BODY_BYTES + 1)
            if len(response_body) > MAX_BODY_BYTES:
                self.send_error(502, '上游响应内容过大')
                return

            self.send_response(upstream.status)
            for name in ('Content-Type', 'Cache-Control', 'X-Content-Type-Options'):
                value = upstream.getheader(name)
                if value is not None:
                    self.send_header(name, value)
            self.send_header('Content-Length', str(len(response_body)))
            if origin is not None:
                self._add_cors_headers(origin)
            self.end_headers()
            if response_body:
                self.wfile.write(response_body)
        except (OSError, TimeoutError) as error:
            print(f'上游 API 连接失败：{type(error).__name__}', flush=True)
            self.send_error(502, '无法安全连接远端 API')
        finally:
            connection.close()

    def _add_cors_headers(self, origin):
        self.send_header('Access-Control-Allow-Origin', origin)
        self.send_header('Vary', 'Origin')

    def log_message(self, format, *args):
        # 不在终端记录路径、查询参数或账号活动。
        return


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 8091), WebApiProxy)
    print('本地 Web API 代理已启动：http://127.0.0.1:8091/ → 远端 API', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
