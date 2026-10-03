import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

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
  static const _tables = [
    'weight_entries',
    'height_entries',
    'meal_entries',
    'workout_muscles',
    'workout_plans',
    'workout_logs',
    'workout_settings'
  ];

  Future<LegacySnapshot?> scan() async {
    final path = '${await getDatabasesPath()}/daily_consume.db';
    if (!await databaseExists(path)) return pending = null;
    // Read the original file without creating, upgrading or writing a database.
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      final names = (await db
              .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
          .map((row) => row['name'] as String)
          .toSet();
      final unknown =
          names.difference({..._tables, 'android_metadata', 'sqlite_sequence'});
      if (unknown.any((name) => !name.startsWith('sqlite_'))) {
        throw const ApiException('发现未识别的本机数据表，请保留旧数据并联系维护者');
      }
      final tables = <String, List<Map<String, Object?>>>{};
      for (final name in _tables) {
        if (names.contains(name))
          tables[name] = await db.query(name, orderBy: 'rowid ASC');
      }
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
    } finally {
      await db.close();
    }
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
    // Delete only after the server transaction committed and the receipt matched.
    await deleteDatabase(snapshot.path);
    pending = null;
    api.dataImported();
  }
}
