import 'dart:convert';

import 'api_client.dart';

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

class WorkoutMuscle {
  const WorkoutMuscle(
      {required this.name, required this.colorValue, this.builtIn = false});

  final String name;
  final int colorValue;
  final bool builtIn;

  factory WorkoutMuscle.fromMap(Map<String, Object?> row) => WorkoutMuscle(
        name: row['name']! as String,
        colorValue: row['color_value']! as int,
        builtIn: (row['built_in']! as int) == 1,
      );
}

class WorkoutLog {
  const WorkoutLog({required this.date, required this.muscles});

  final DateTime date;
  final List<WorkoutMuscle> muscles;

  factory WorkoutLog.fromMap(Map<String, Object?> row) => WorkoutLog(
        date: dateFromKey(row['date']! as String),
        muscles: (row['muscles'] is String
                ? jsonDecode(row['muscles']! as String) as List<dynamic>
                : row['muscles'] as List<dynamic>)
            .map((item) => WorkoutMuscle(
                  name: item['name'] as String,
                  colorValue: item['color'] as int,
                ))
            .toList(),
      );
}

class WorkoutDayPlan {
  const WorkoutDayPlan({required this.muscles, this.isRest = false});

  final List<String> muscles;
  final bool isRest;

  factory WorkoutDayPlan.fromMap(Map<String, Object?> row) => WorkoutDayPlan(
        muscles: (row['muscles'] is String
                ? jsonDecode(row['muscles']! as String) as List<dynamic>
                : row['muscles'] as List<dynamic>)
            .cast<String>(),
        isRest: (row['is_rest']! as int) == 1,
      );
}

class PomodoroSettings {
  const PomodoroSettings({
    this.focusMinutes = 25,
    this.shortBreakMinutes = 5,
    this.longBreakMinutes = 15,
    this.roundsPerLongBreak = 4,
  });

  final int focusMinutes;
  final int shortBreakMinutes;
  final int longBreakMinutes;
  final int roundsPerLongBreak;

  factory PomodoroSettings.fromMap(Map<String, Object?> row) =>
      PomodoroSettings(
        focusMinutes: row['focus_minutes']! as int,
        shortBreakMinutes: row['short_break_minutes']! as int,
        longBreakMinutes: row['long_break_minutes']! as int,
        roundsPerLongBreak: row['rounds_per_long_break']! as int,
      );
}

class PomodoroTask {
  const PomodoroTask({required this.id, required this.title});

  final int id;
  final String title;

  factory PomodoroTask.fromMap(Map<String, Object?> row) => PomodoroTask(
        id: row['id']! as int,
        title: row['title']! as String,
      );
}

class PomodoroSession {
  const PomodoroSession({
    required this.taskTitle,
    required this.durationMinutes,
    required this.startedAt,
  });

  final String taskTitle;
  final int durationMinutes;
  final DateTime startedAt;

  factory PomodoroSession.fromMap(Map<String, Object?> row) => PomodoroSession(
        taskTitle: row['task_title']! as String,
        durationMinutes: row['duration_minutes']! as int,
        startedAt: DateTime.parse(row['started_at']! as String).toLocal(),
      );
}

// Keep the existing page-facing API; all business storage now lives on the server.
class AppDatabase {
  AppDatabase._();
  static final instance = AppDatabase._();
  final _api = ApiClient.instance;

  Future<List<Map<String, Object?>>> _rows(String path,
          {Map<String, String>? query}) async =>
      (await _api.request('GET', path, query: query) as List)
          .map((row) => Map<String, Object?>.from(row as Map))
          .toList();

  Future<List<BodyEntry>> getWeights() async => (await _rows('weights'))
      .map((row) => BodyEntry(
          date: dateFromKey(row['date'] as String),
          value: (row['grams'] as int) / 1000))
      .toList();
  Future<List<BodyEntry>> getHeights() async => (await _rows('heights'))
      .map((row) => BodyEntry(
          date: dateFromKey(row['date'] as String),
          value: (row['millimeters'] as int) / 10))
      .toList();
  Future<double?> getGoalWeight() async {
    final settings = await _api.request('GET', 'body/settings') as Map;
    final grams = settings['goal_weight_grams'] as int?;
    return grams == null ? null : grams / 1000;
  }

  Future<void> saveGoalWeight(double? kilograms) async {
    await _api.request('PUT', 'body/settings', body: {
      'goal_weight_grams':
          kilograms == null ? null : (kilograms * 1000).round(),
    });
  }

  Future<void> saveWeight(DateTime date, double kilograms) async {
    await _api.request('PUT', 'weights',
        body: {'date': dateKey(date), 'grams': (kilograms * 1000).round()});
  }

  Future<void> saveHeight(DateTime date, double centimeters) async {
    await _api.request('PUT', 'heights', body: {
      'date': dateKey(date),
      'millimeters': (centimeters * 10).round()
    });
  }

  Future<List<MealEntry>> getMealsForDate(DateTime date) =>
      getMealsBetween(date, date);
  Future<List<MealEntry>> getMealsBetween(DateTime start, DateTime end) async =>
      (await _rows('meals',
              query: {'start': dateKey(start), 'end': dateKey(end)}))
          .map(MealEntry.fromMap)
          .toList();
  Future<void> saveMeal(MealEntry meal) async {
    await _api.request('PUT', 'meals', body: {
      'date': dateKey(meal.date),
      'meal_type': meal.mealType,
      'foods': meal.foods,
      'expense_cents': meal.expenseCents,
    });
  }

  Future<void> deleteMeal(DateTime date, String mealType) async {
    await _api.request('DELETE', 'meals',
        query: {'date': dateKey(date), 'meal_type': mealType});
  }

  Future<List<WorkoutMuscle>> getWorkoutMuscles() async =>
      (await _rows('workout/muscles')).map(WorkoutMuscle.fromMap).toList();
  Future<void> addWorkoutMuscle(String name, int colorValue) async {
    await _api.request('POST', 'workout/muscles',
        body: {'name': name, 'color_value': colorValue});
  }

  Future<void> setWorkoutMuscleColor(String name, int colorValue) async {
    await _api.request('PUT', 'workout/muscles',
        body: {'name': name, 'color_value': colorValue});
  }

  Future<void> deleteWorkoutMuscle(String name) async {
    await _api.request('DELETE', 'workout/muscles', query: {'name': name});
  }

  Future<int> getWorkoutGoal() async =>
      (await _api.request('GET', 'workout/settings'))['weekly_goal'] as int;
  Future<Map<int, WorkoutDayPlan>> getWorkoutPlans() async => {
        for (final row in await _rows('workout/plans'))
          row['weekday'] as int: WorkoutDayPlan.fromMap(row),
      };
  Future<void> saveWorkoutSchedule(
      int goal, Map<int, WorkoutDayPlan> plans) async {
    await _api.request('PUT', 'workout/schedule', body: {
      'weekly_goal': goal,
      'plans': [
        for (final entry in plans.entries)
          {
            'weekday': entry.key,
            'muscles': entry.value.isRest ? <String>[] : entry.value.muscles,
            'is_rest': entry.value.isRest ? 1 : 0
          },
      ]
    });
  }

  Future<List<WorkoutLog>> getWorkoutLogsBetween(
          DateTime start, DateTime end) async =>
      (await _rows('workout/logs',
              query: {'start': dateKey(start), 'end': dateKey(end)}))
          .map(WorkoutLog.fromMap)
          .toList();
  Future<void> saveWorkoutLog(
      DateTime date, List<WorkoutMuscle> muscles) async {
    await _api.request('POST', 'workout/logs', body: {
      'date': dateKey(date),
      'muscles': [
        for (final muscle in muscles)
          {'name': muscle.name, 'color': muscle.colorValue},
      ]
    });
  }

  Future<void> deleteWorkoutLog(DateTime date) async {
    await _api
        .request('DELETE', 'workout/logs', query: {'date': dateKey(date)});
  }

  Future<List<PomodoroTask>> getPomodoroTasks() async =>
      (await _rows('pomodoro/tasks')).map(PomodoroTask.fromMap).toList();

  Future<PomodoroSettings> getPomodoroSettings() async =>
      PomodoroSettings.fromMap(Map<String, Object?>.from(
          await _api.request('GET', 'pomodoro/settings') as Map));

  Future<void> savePomodoroSettings(PomodoroSettings settings) async {
    await _api.request('PUT', 'pomodoro/settings', body: {
      'focus_minutes': settings.focusMinutes,
      'short_break_minutes': settings.shortBreakMinutes,
      'long_break_minutes': settings.longBreakMinutes,
      'rounds_per_long_break': settings.roundsPerLongBreak,
    });
  }

  Future<PomodoroTask> savePomodoroTask(String title) async =>
      PomodoroTask.fromMap(Map<String, Object?>.from(await _api
          .request('POST', 'pomodoro/tasks', body: {'title': title}) as Map));

  Future<void> deletePomodoroTask(int id) async {
    await _api.request('DELETE', 'pomodoro/tasks', query: {'id': '$id'});
  }

  Future<List<PomodoroSession>> getPomodoroSessions(
          DateTime start, DateTime end) async =>
      (await _rows('pomodoro/sessions',
              query: {'start': dateKey(start), 'end': dateKey(end)}))
          .map(PomodoroSession.fromMap)
          .toList();

  Future<void> savePomodoroSession({
    required String requestId,
    required int taskId,
    required String taskTitle,
    required int durationMinutes,
    required DateTime startedAt,
    required DateTime completedAt,
  }) async {
    await _api.request('POST', 'pomodoro/sessions', body: {
      'client_request_id': requestId,
      'task_id': taskId,
      'task_title': taskTitle,
      'duration_minutes': durationMinutes,
      'started_at': startedAt.toUtc().toIso8601String(),
      'completed_at': completedAt.toUtc().toIso8601String(),
    });
  }
}
