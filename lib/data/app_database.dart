import 'package:sqflite/sqflite.dart';

String dateKey(DateTime date) {
  final local = DateTime(date.year, date.month, date.day);
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

DateTime dateFromKey(String value) => DateTime.parse(value);

class BodyEntry {
  const BodyEntry({required this.date, required this.value});

  final DateTime date;
  final double value;
}

class MealEntry {
  const MealEntry({
    required this.date,
    required this.mealType,
    required this.foods,
    required this.expenseCents,
  });

  final DateTime date;
  final String mealType;
  final String foods;
  final int expenseCents;

  double get expense => expenseCents / 100;

  factory MealEntry.fromMap(Map<String, Object?> row) => MealEntry(
        date: dateFromKey(row['date']! as String),
        mealType: row['meal_type']! as String,
        foods: row['foods']! as String,
        expenseCents: row['expense_cents']! as int,
      );
}

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final directory = await getDatabasesPath();
    _database = await openDatabase(
      '$directory/daily_consume.db',
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE weight_entries (
            date TEXT PRIMARY KEY,
            grams INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE height_entries (
            date TEXT PRIMARY KEY,
            millimeters INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE meal_entries (
            date TEXT NOT NULL,
            meal_type TEXT NOT NULL,
            foods TEXT NOT NULL,
            expense_cents INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (date, meal_type)
          )
        ''');
      },
    );
    return _database!;
  }

  Future<List<BodyEntry>> getWeights() async {
    final rows = await (await database).query(
      'weight_entries',
      orderBy: 'date ASC',
    );
    return rows
        .map((row) => BodyEntry(
              date: dateFromKey(row['date']! as String),
              value: (row['grams']! as int) / 1000,
            ))
        .toList();
  }

  Future<List<BodyEntry>> getHeights() async {
    final rows = await (await database).query(
      'height_entries',
      orderBy: 'date ASC',
    );
    return rows
        .map((row) => BodyEntry(
              date: dateFromKey(row['date']! as String),
              value: (row['millimeters']! as int) / 10,
            ))
        .toList();
  }

  Future<void> saveWeight(DateTime date, double kilograms) async {
    await (await database).insert(
      'weight_entries',
      {'date': dateKey(date), 'grams': (kilograms * 1000).round()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveHeight(DateTime date, double centimeters) async {
    await (await database).insert(
      'height_entries',
      {'date': dateKey(date), 'millimeters': (centimeters * 10).round()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MealEntry>> getMealsForDate(DateTime date) async {
    final rows = await (await database).query(
      'meal_entries',
      where: 'date = ?',
      whereArgs: [dateKey(date)],
    );
    return rows.map(MealEntry.fromMap).toList();
  }

  Future<List<MealEntry>> getMealsBetween(DateTime start, DateTime end) async {
    final rows = await (await database).query(
      'meal_entries',
      where: 'date >= ? AND date <= ?',
      whereArgs: [dateKey(start), dateKey(end)],
      orderBy: 'date ASC',
    );
    return rows.map(MealEntry.fromMap).toList();
  }

  Future<void> saveMeal(MealEntry meal) async {
    await (await database).insert(
      'meal_entries',
      {
        'date': dateKey(meal.date),
        'meal_type': meal.mealType,
        'foods': meal.foods,
        'expense_cents': meal.expenseCents,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteMeal(DateTime date, String mealType) async {
    await (await database).delete(
      'meal_entries',
      where: 'date = ? AND meal_type = ?',
      whereArgs: [dateKey(date), mealType],
    );
  }
}
