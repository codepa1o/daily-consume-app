import 'package:sqflite/sqflite.dart';

import 'api_client.dart';

const _tables = [
  'weight_entries',
  'height_entries',
  'meal_entries',
  'workout_muscles',
  'workout_plans',
  'workout_logs',
  'workout_settings',
];

Future<Map<String, Object?>?> scan() async {
  final path = '${await getDatabasesPath()}/daily_consume.db';
  if (!await databaseExists(path)) return null;
  // 只读读取旧数据库，不创建、升级或写入数据库。
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
      if (names.contains(name)) {
        tables[name] = await db.query(name, orderBy: 'rowid ASC');
      }
    }
    return {'path': path, 'tables': tables};
  } finally {
    await db.close();
  }
}

Future<void> delete(String path) => deleteDatabase(path);
