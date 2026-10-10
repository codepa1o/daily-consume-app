import 'package:flutter/services.dart';

import 'travel_export_types.dart';

const _channel = MethodChannel('daily_consume/travel_exports');

Future<void> shareTravelFiles(
  List<TravelExportFile> files, {
  required String subject,
}) async {
  await _channel.invokeMethod<void>('shareFiles', {
    'subject': subject,
    'files': [
      for (final file in files)
        {
          'name': file.name,
          'mimeType': file.mimeType,
          'bytes': file.bytes,
        },
    ],
  });
}
