import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'travel_export_types.dart';

Future<void> shareTravelFiles(
  List<TravelExportFile> files, {
  required String subject,
}) async {
  for (final file in files) {
    final blob = web.Blob(
      [file.bytes.toJS].toJS,
      web.BlobPropertyBag(type: file.mimeType),
    );
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = file.name
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  }
}
