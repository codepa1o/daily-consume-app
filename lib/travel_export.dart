import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'travel_export_platform.dart' as export_platform;
import 'travel_export_types.dart';

class TravelExport {
  static Future<List<Uint8List>> _capture(List<GlobalKey> keys) async {
    final images = <Uint8List>[];
    for (final key in keys) {
      final render = key.currentContext?.findRenderObject();
      if (render is! RenderRepaintBoundary || render.size.isEmpty) continue;
      final image = await render.toImage(pixelRatio: 1.4);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data != null) images.add(data.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }
    if (images.isEmpty) throw StateError('行程页面尚未完成渲染');
    return images;
  }

  static Future<void> shareImages(String city, List<GlobalKey> keys) async {
    final images = await _combineImages(await _capture(keys));
    final safeCity = _safeFileName(city);
    await export_platform.shareTravelFiles(
      [
        for (var index = 0; index < images.length; index++)
          TravelExportFile(
            name:
                '旅游计划_${safeCity}_${(index + 1).toString().padLeft(2, '0')}.png',
            mimeType: 'image/png',
            bytes: images[index],
          ),
      ],
      subject: '$city旅行计划',
    );
  }

  static Future<void> sharePdf(String city, List<GlobalKey> keys) async {
    final images = await _capture(keys);
    final document = pw.Document();
    for (final bytes in images) {
      final image = pw.MemoryImage(bytes);
      document.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(18),
        build: (_) => pw.Center(
          child: pw.Image(image, fit: pw.BoxFit.contain),
        ),
      ));
    }
    final safeCity = _safeFileName(city);
    await export_platform.shareTravelFiles(
      [
        TravelExportFile(
          name: '旅游计划_$safeCity.pdf',
          mimeType: 'application/pdf',
          bytes: Uint8List.fromList(await document.save()),
        ),
      ],
      subject: '$city旅行计划 PDF',
    );
  }

  static String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim().isEmpty
          ? '行程'
          : value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  static Future<List<Uint8List>> _combineImages(List<Uint8List> pages) async {
    final decoded = <ui.Image>[];
    try {
      for (final page in pages) {
        final codec = await ui.instantiateImageCodec(page);
        decoded.add((await codec.getNextFrame()).image);
        codec.dispose();
      }

      const maxImageHeight = 12000;
      const gap = 20;
      final output = <Uint8List>[];
      var group = <ui.Image>[];
      var width = 0;
      var height = 0;
      for (final image in decoded) {
        final nextHeight = height + (group.isEmpty ? 0 : gap) + image.height;
        if (group.isNotEmpty && nextHeight > maxImageHeight) {
          output.add(await _stitch(group, width, height));
          group = [];
          width = 0;
          height = 0;
        }
        width = width > image.width ? width : image.width;
        height += (group.isEmpty ? 0 : gap) + image.height;
        group.add(image);
      }
      if (group.isNotEmpty) output.add(await _stitch(group, width, height));
      return output;
    } finally {
      for (final image in decoded) {
        image.dispose();
      }
    }
  }

  static Future<Uint8List> _stitch(
    List<ui.Image> images,
    int width,
    int height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
        recorder, ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()))
      ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    var top = 0.0;
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      final left = (width - image.width) / 2;
      canvas.drawImage(image, ui.Offset(left, top), ui.Paint());
      top += image.height + (index == images.length - 1 ? 0 : 20);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('无法编码行程图片');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
}
