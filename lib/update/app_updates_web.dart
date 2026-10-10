import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class UpdateScope {
  static WebUpdateVersion? maybeOf(BuildContext context) => null;
}

class WebUpdateVersion {
  const WebUpdateVersion(this.currentVersion);
  final String currentVersion;
}

class UpdateHost extends StatelessWidget {
  const UpdateHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

Future<void> checkForAppUpdates(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('网页版更新'),
      content: const Text('网页版由服务器统一更新，请刷新浏览器页面获取最新版本。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('知道了')),
      ],
    ),
  );
}

Future<void> showInstalledUpdateLog(BuildContext context) async {
  final history = jsonDecode(
          await rootBundle.loadString('assets/release_history.json'))
      as Map<String, dynamic>;
  final releases = List<Map<String, dynamic>>.from(
      (history['releases'] as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map)));
  final release = jsonDecode(
          await rootBundle.loadString('assets/release_notes.json'))
      as Map<String, dynamic>;
  final currentCode = release['versionCode'] as int;
  final matching =
      releases.where((entry) => entry['versionCode'] == currentCode).toList();
  releases.removeWhere((entry) => entry['versionCode'] == currentCode);
  releases.add({
    'versionCode': currentCode,
    'versionName': release['versionName'],
    'publishedAt': matching.isEmpty ? '' : matching.first['publishedAt'],
    'releaseNotes': release['releaseNotes'],
  });
  releases.sort((a, b) {
    final aDate = DateTime.tryParse(a['publishedAt'] as String? ?? '') ??
        DateTime(1970);
    final bDate = DateTime.tryParse(b['publishedAt'] as String? ?? '') ??
        DateTime(1970);
    final byDate = bDate.compareTo(aDate);
    return byDate != 0
        ? byDate
        : (b['versionCode'] as int).compareTo(a['versionCode'] as int);
  });
  if (!context.mounted) return;
  final size = MediaQuery.sizeOf(context);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('版本更新日志'),
      content: SizedBox(
        width: (size.width * .78).clamp(280.0, 440.0).toDouble(),
        height: (size.height * .68).clamp(240.0, 560.0).toDouble(),
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            for (var index = 0; index < releases.length; index++)
              _ReleaseHistoryEntry(
                release: releases[index],
                current: releases[index]['versionCode'] == currentCode,
                showDivider: index != releases.length - 1,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    ),
  );
}

class _ReleaseHistoryEntry extends StatelessWidget {
  const _ReleaseHistoryEntry({
    required this.release,
    required this.current,
    required this.showDivider,
  });

  final Map<String, dynamic> release;
  final bool current;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(release['publishedAt'] as String? ?? '')
        ?.toLocal();
    final dateLabel = date == null
        ? current
            ? '当前版本'
            : '时间未记录'
        : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: showDivider ? 18 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text('版本 ${release['versionName']}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (current)
              Text('当前',
                  style: TextStyle(color: colors.primary, fontSize: 12)),
          ]),
          const SizedBox(height: 3),
          Text(dateLabel,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 8),
          for (final note in release['releaseNotes'] as List)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text('• $note'),
            ),
          if (showDivider) const Divider(height: 1),
        ],
      ),
    );
  }
}
