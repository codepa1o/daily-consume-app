import 'dart:typed_data';

import 'research_files.dart';

Future<ResearchDirectory> researchDirectory() async =>
    const ResearchDirectory(label: '本地文献');
Future<ResearchDirectory?> chooseResearchDirectory() async => null;
Future<ResearchDirectory> useDefaultResearchDirectory() async =>
    const ResearchDirectory(label: '本地文献');
Future<List<ResearchDownloadedFile>> listResearchFiles() async => const [];
Future<ResearchPdfSink> beginResearchPdf(String filename) =>
    Future.error(UnsupportedError('当前平台不支持保存 PDF'));
Future<void> writeResearchPdfChunk(
        ResearchPdfSink sink, Uint8List chunk) =>
    Future.error(UnsupportedError('当前平台不支持保存 PDF'));
Future<ResearchDownloadedFile> finishResearchPdf(ResearchPdfSink sink) =>
    Future.error(UnsupportedError('当前平台不支持保存 PDF'));
Future<void> abortResearchPdf(ResearchPdfSink sink) async {}
Future<void> openResearchPdf(String uri) =>
    Future.error(UnsupportedError('当前平台不支持打开 PDF'));
Future<void> openResearchUrl(String url) async {}
