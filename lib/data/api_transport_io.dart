import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

Future<http.Client> createApiHttpClient() async {
  final certificate = await rootBundle.load('assets/server_ca.pem');
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(certificate.buffer
        .asUint8List(certificate.offsetInBytes, certificate.lengthInBytes));
  return IOClient(HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 12));
}
