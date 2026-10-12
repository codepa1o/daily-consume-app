import 'dart:typed_data';

import 'research_files_stub.dart'
    if (dart.library.io) 'research_files_io.dart'
    if (dart.library.js_interop) 'research_files_web.dart' as platform;

class ResearchDirectory {
  const ResearchDirectory({required this.label, this.custom = false});

  final String label;
  final bool custom;
}

class ResearchDownloadedFile {
  const ResearchDownloadedFile({
    required this.name,
    required this.uri,
    required this.size,
    required this.modifiedAt,
  });

  final String name;
  final String uri;
  final int size;
  final DateTime modifiedAt;

  factory ResearchDownloadedFile.fromMap(Map<String, dynamic> value) =>
      ResearchDownloadedFile(
        name: value['name'] as String,
        uri: value['uri'] as String,
        size: value['size'] as int? ?? 0,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(
            value['modifiedAt'] as int? ?? 0),
      );
}

class ResearchPdfSink {
  const ResearchPdfSink({required this.id, required this.name});

  final String id;
  final String name;
}

Future<ResearchDirectory> researchDirectory() => platform.researchDirectory();
Future<ResearchDirectory?> chooseResearchDirectory() =>
    platform.chooseResearchDirectory();
Future<ResearchDirectory> useDefaultResearchDirectory() =>
    platform.useDefaultResearchDirectory();
Future<List<ResearchDownloadedFile>> listResearchFiles() =>
    platform.listResearchFiles();
Future<ResearchPdfSink> beginResearchPdf(String filename) =>
    platform.beginResearchPdf(filename);
Future<void> writeResearchPdfChunk(ResearchPdfSink sink, Uint8List chunk) =>
    platform.writeResearchPdfChunk(sink, chunk);
Future<ResearchDownloadedFile> finishResearchPdf(ResearchPdfSink sink) =>
    platform.finishResearchPdf(sink);
Future<void> abortResearchPdf(ResearchPdfSink sink) =>
    platform.abortResearchPdf(sink);
Future<void> openResearchPdf(String uri) => platform.openResearchPdf(uri);
Future<void> openResearchUrl(String url) => platform.openResearchUrl(url);
