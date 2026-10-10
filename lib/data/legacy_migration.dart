import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'legacy_migration_store_io.dart'
    if (dart.library.js_interop) 'legacy_migration_store_web.dart' as local;

class LegacySnapshot {
  const LegacySnapshot(this.path, this.tables, this.importId, this.sourceId);
  final String path;
  final Map<String, List<Map<String, Object?>>> tables;
  final String importId;
  final String sourceId;
  Map<String, int> get counts =>
      tables.map((key, rows) => MapEntry(key, rows.length));
  int get total => counts.values.fold(0, (sum, value) => sum + value);
}

class LegacyMigration {
  static final instance = LegacyMigration();
  LegacySnapshot? pending;
  static const _storage = FlutterSecureStorage();
  static const _sourceKey = 'daily_consume_legacy_source';
  Future<LegacySnapshot?> scan() async {
    final sourceData = await local.scan();
    if (sourceData == null) return pending = null;
    final path = sourceData['path'] as String;
    final tables = <String, List<Map<String, Object?>>>{
      for (final entry in (sourceData['tables'] as Map).entries)
        entry.key as String: (entry.value as List)
            .map((row) => Map<String, Object?>.from(row as Map))
            .toList(),
    };
    var source = await _storage.read(key: _sourceKey);
    if (source == null) {
      final random = Random.secure();
      source = List.generate(32,
              (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await _storage.write(key: _sourceKey, value: source);
    }
    final id =
        sha256.convert(utf8.encode(source + jsonEncode(tables))).toString();
    return pending = LegacySnapshot(path, tables, id, source);
  }

  Future<void> importToCurrentAccount() async {
    final snapshot = pending;
    if (snapshot == null) return;
    final api = ApiClient.instance;
    final owner = api.account?.id;
    if (owner == null) throw const ApiException('请先登录');
    final receipt = await api.request('POST', 'legacy/import', body: {
      'import_id': snapshot.importId,
      'source_id': snapshot.sourceId,
      'tables': snapshot.tables,
    }) as Map<String, dynamic>;
    final counts = Map<String, dynamic>.from(receipt['counts'] as Map);
    if (receipt['import_id'] != snapshot.importId ||
        counts.length != snapshot.counts.length ||
        snapshot.counts.entries
            .any((entry) => counts[entry.key] != entry.value)) {
      throw const ApiException('服务器导入核对失败，本机数据已保留');
    }
    final current = await scan();
    if (api.account?.id != owner || current?.importId != snapshot.importId) {
      throw const ApiException('账号或本机数据发生变化，本机数据已保留，请重试');
    }
    // 仅在服务器事务成功且回执核对无误后删除本机数据。
    await local.delete(snapshot.path);
    pending = null;
    api.dataImported();
  }
}
