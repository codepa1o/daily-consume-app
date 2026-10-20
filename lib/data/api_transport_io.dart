import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

Future<http.Client> createApiHttpClient() async {
  final certificate = await rootBundle.load('assets/server_ca.pem');
  // 仅信任旧服务器证书及 Let's Encrypt 根；Dart 仍会校验 IP SAN 和证书有效期。
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(certificate.buffer
        .asUint8List(certificate.offsetInBytes, certificate.lengthInBytes));
  return IOClient(HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 12));
}
