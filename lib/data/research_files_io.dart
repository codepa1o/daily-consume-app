import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'research_files.dart';

const _channel = MethodChannel('daily_consume/research_files');

Future<ResearchDirectory> researchDirectory() async =>
    _directory(await _channel.invokeMapMethod<String, dynamic>('directory'));

Future<ResearchDirectory?> chooseResearchDirectory() async {
  final value = await _channel.invokeMapMethod<String, dynamic>('chooseDirectory');
  return value == null ? null : _directory(value);
}

Future<ResearchDirectory> useDefaultResearchDirectory() async =>
    _directory(await _channel.invokeMapMethod<String, dynamic>('useDefaultDirectory'));

Future<List<ResearchDownloadedFile>> listResearchFiles() async {
  final values = await _channel.invokeListMethod<Map<Object?, Object?>>('listPapers');
  return [
    for (final value in values ?? [])
      ResearchDownloadedFile.fromMap(Map<String, dynamic>.from(value)),
  ];
}

Future<ResearchPdfSink> beginResearchPdf(String filename) async {
  final value = await _channel.invokeMapMethod<String, dynamic>(
    'beginPdf',
    {'name': filename},
  );
  if (value == null) throw StateError('PDF 保存失败');
  return ResearchPdfSink(
    id: value['id'] as String,
    name: value['name'] as String,
  );
}

Future<void> writeResearchPdfChunk(
        ResearchPdfSink sink, Uint8List chunk) =>
    _channel.invokeMethod<void>('writePdfChunk', {
      'id': sink.id,
      'bytes': chunk,
    });

Future<ResearchDownloadedFile> finishResearchPdf(
    ResearchPdfSink sink) async {
  final value = await _channel.invokeMapMethod<String, dynamic>(
    'finishPdf',
    sink.id,
  );
  if (value == null) throw StateError('PDF 保存失败');
  return ResearchDownloadedFile.fromMap(value);
}

Future<void> abortResearchPdf(ResearchPdfSink sink) =>
    _channel.invokeMethod<void>('abortPdf', sink.id);

Future<void> openResearchPdf(String uri) =>
    _channel.invokeMethod<void>('openPdf', uri);

Future<void> openResearchUrl(String url) =>
    _channel.invokeMethod<void>('openUrl', url);

ResearchDirectory _directory(Map<String, dynamic>? value) =>
    ResearchDirectory(
      label: value?['label'] as String? ?? '本地文献',
      custom: value?['custom'] as bool? ?? false,
    );
