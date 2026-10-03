import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AuthStatus { restoring, signedOut, signedIn, unavailable }

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode = 0});
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}

class Account {
  const Account(
      {required this.id,
      required this.username,
      required this.nickname,
      required this.createdAt});
  final int id;
  final String username;
  final String nickname;
  final DateTime createdAt;
  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as int,
        username: json['username'] as String,
        nickname: json['nickname'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );
}

class ApiClient extends ChangeNotifier {
  ApiClient._();
  static final instance = ApiClient._();
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'daily_consume_session';
  static final _base = Uri.parse(const String.fromEnvironment('API_BASE_URL',
      defaultValue: 'https://47.99.142.117/api/v1/'));
  HttpClient? _client;
  String? _token;
  Future<void>? _clearingSession;
  Account? account;
  AuthStatus status = AuthStatus.restoring;
  String message = '';
  int dataRevision = 0;

  Future<void> _prepare() async {
    if (_base.scheme != 'https' || _base.host.isEmpty) {
      throw const ApiException('服务器地址必须使用 HTTPS');
    }
    if (_client != null) return;
    final certificate = await rootBundle.load('assets/server_ca.pem');
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(certificate.buffer
          .asUint8List(certificate.offsetInBytes, certificate.lengthInBytes));
    _client = HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 12);
  }

  Future<void> restore() async {
    status = AuthStatus.restoring;
    message = '';
    notifyListeners();
    try {
      await _prepare();
      _token = await _storage.read(key: _tokenKey);
      if (_token == null) {
        status = AuthStatus.signedOut;
      } else {
        account = Account.fromJson(
            await request('GET', 'me') as Map<String, dynamic>);
        status = AuthStatus.signedIn;
      }
    } catch (error) {
      if (status != AuthStatus.signedOut) {
        status = AuthStatus.unavailable;
        message = error is ApiException ? error.message : '无法恢复登录，请重试';
      }
    }
    notifyListeners();
  }

  Future<void> signIn(String username, String password,
      {bool register = false, String nickname = ''}) async {
    final clearing = _clearingSession;
    if (clearing != null) await clearing;
    final credentials = {'username': username.trim(), 'password': password};
    if (register) {
      await request('POST', 'auth/register',
          body: {...credentials, 'nickname': nickname.trim()},
          authenticated: false);
    }
    Map<String, dynamic> response;
    try {
      response = await request('POST', 'auth/login',
          body: credentials, authenticated: false) as Map<String, dynamic>;
    } on ApiException catch (error) {
      if (register)
        throw ApiException('账号已创建，请切换到登录页后重试。${error.message}',
            statusCode: error.statusCode);
      rethrow;
    }
    final token = response['token'] as String;
    try {
      await _storage.write(key: _tokenKey, value: token);
    } catch (_) {
      // Revoke the new session if this device could not store it safely.
      _token = token;
      try {
        await request('POST', 'auth/logout');
      } catch (_) {}
      _token = null;
      throw const ApiException('无法安全保存登录状态，请重试');
    }
    _token = token;
    account = Account.fromJson(response['user'] as Map<String, dynamic>);
    status = AuthStatus.signedIn;
    message = '';
    notifyListeners();
  }

  Future<void> signOut() async {
    final token = _token;
    try {
      await request('POST', 'auth/logout');
    } on ApiException catch (error) {
      if (error.statusCode != 401) rethrow;
    }
    if (token == _token) await _clearSession(token);
  }

  Future<void> _clearSession(String? expectedToken) async {
    if (_token != expectedToken) return;
    final current = _clearingSession;
    if (current != null) return current;
    final clearing = _finishClearingSession(expectedToken);
    _clearingSession = clearing;
    try {
      await clearing;
    } finally {
      if (identical(_clearingSession, clearing)) _clearingSession = null;
    }
  }

  Future<void> _finishClearingSession(String? expectedToken) async {
    try {
      await _storage.delete(key: _tokenKey);
    } finally {
      if (_token == expectedToken) {
        _token = null;
        account = null;
        status = AuthStatus.signedOut;
        notifyListeners();
      }
    }
  }

  void dataImported() {
    dataRevision++;
    notifyListeners();
  }

  Future<dynamic> request(String method, String path,
      {Object? body,
      Map<String, String>? query,
      bool authenticated = true}) async {
    await _prepare();
    final token = _token;
    if (authenticated && token == null)
      throw const ApiException('请先登录', statusCode: 401);
    final base = _base.path.endsWith('/')
        ? _base
        : _base.replace(path: '${_base.path}/');
    final uri = base.resolve(path).replace(queryParameters: query);
    HttpClientRequest? outgoing;
    try {
      outgoing = await _client!
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      outgoing.followRedirects = false;
      outgoing.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (authenticated)
        outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        outgoing.headers.contentType = ContentType.json;
        outgoing.write(jsonEncode(body));
      }
      final response =
          await outgoing.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      if (authenticated && token != _token)
        throw const ApiException('账号已切换，请重新加载');
      dynamic decoded;
      try {
        decoded = text.isEmpty ? null : jsonDecode(text);
      } on FormatException catch (_) {}
      if (response.statusCode >= 200 && response.statusCode < 300)
        return decoded;
      if (authenticated && response.statusCode == 401 && token == _token) {
        message = '登录已过期，请重新登录';
        await _clearSession(token);
      }
      final detail = decoded is Map ? decoded['detail'] : null;
      throw ApiException(
          detail is String
              ? detail
              : response.statusCode == 429
                  ? '操作过于频繁，请稍后重试'
                  : '服务器暂时不可用，请重试',
          statusCode: response.statusCode);
    } on TimeoutException catch (_) {
      outgoing?.abort();
      throw const ApiException('连接超时，请检查网络后重试');
    } on HandshakeException catch (_) {
      throw const ApiException('服务器安全连接失败，请检查设备时间或更新应用');
    } on IOException catch (_) {
      throw const ApiException('无法连接服务器，请检查网络后重试');
    }
  }
}
