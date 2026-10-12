import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'research_files.dart';

final _savedFiles = <ResearchDownloadedFile>[];
final _urls = <String>{};
final _pendingPdfs = <String, List<Uint8List>>{};

Future<ResearchDirectory> researchDirectory() async =>
    const ResearchDirectory(label: '由浏览器管理下载位置');

Future<ResearchDirectory?> chooseResearchDirectory() async => null;

Future<ResearchDirectory> useDefaultResearchDirectory() async =>
    const ResearchDirectory(label: '由浏览器管理下载位置');

Future<List<ResearchDownloadedFile>> listResearchFiles() async =>
    List.of(_savedFiles.reversed);

Future<ResearchPdfSink> beginResearchPdf(String filename) async {
  final id = DateTime.now().microsecondsSinceEpoch.toString();
  _pendingPdfs[id] = [];
  return ResearchPdfSink(id: id, name: filename);
}

Future<void> writeResearchPdfChunk(
    ResearchPdfSink sink, Uint8List chunk) async {
  final chunks = _pendingPdfs[sink.id];
  if (chunks == null) throw StateError('PDF 下载已结束');
  chunks.add(chunk);
}

Future<ResearchDownloadedFile> finishResearchPdf(ResearchPdfSink sink) async {
  final chunks = _pendingPdfs.remove(sink.id);
  if (chunks == null) throw StateError('PDF 下载已结束');
  final blob = web.Blob(
    [
      for (final chunk in chunks) chunk.toJS,
    ].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);
  _urls.add(url);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = sink.name
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  final file = ResearchDownloadedFile(
    name: sink.name,
    uri: url,
    size: chunks.fold<int>(0, (total, chunk) => total + chunk.length),
    modifiedAt: DateTime.now(),
  );
  _savedFiles.add(file);
  Timer(const Duration(minutes: 5), () {
    if (_urls.remove(url)) web.URL.revokeObjectURL(url);
  });
  return file;
}

Future<void> abortResearchPdf(ResearchPdfSink sink) async {
  _pendingPdfs.remove(sink.id);
}

Future<void> openResearchPdf(String uri) async {
  if (_urls.contains(uri)) {
    web.window.open(uri, '_blank', 'noopener,noreferrer');
  }
}

Future<void> openResearchUrl(String url) async {
  web.window.open(url, '_blank', 'noopener,noreferrer');
}
