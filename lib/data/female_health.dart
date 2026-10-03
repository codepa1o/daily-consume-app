import 'api_client.dart';
import 'app_database.dart' show dateKey;

// Health records use calendar dates in Asia/Shanghai, not elapsed local hours.
DateTime healthDate(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);
DateTime healthToday() =>
    healthDate(DateTime.now().toUtc().add(const Duration(hours: 8)));
DateTime parseHealthDate(String date) => healthDate(DateTime.parse(date));
List<DateTime> healthDateRange(DateTime start, DateTime end) => [
      for (var day = healthDate(start);
          !day.isAfter(healthDate(end));
          day = day.add(const Duration(days: 1)))
        day,
    ];

class HealthSettings {
  const HealthSettings(
      {this.cycleLength, this.periodLength, this.paused = false});
  final int? cycleLength;
  final int? periodLength;
  final bool paused;
  factory HealthSettings.fromJson(Map<String, dynamic> json) => HealthSettings(
      cycleLength: json['cycle_length'] as int?,
      periodLength: json['period_length'] as int?,
      paused: json['paused'] as bool? ?? false);
  Map<String, dynamic> toJson() => {
        'cycle_length': cycleLength,
        'period_length': periodLength,
        'paused': paused,
      };
}

class MenstrualPeriod {
  const MenstrualPeriod(
      {this.id, required this.start, this.end, required this.dates});
  final int? id;
  final DateTime start;
  final DateTime? end;
  final List<DateTime> dates;
  bool get ongoing => end == null;
  factory MenstrualPeriod.fromJson(Map<String, dynamic> json) =>
      MenstrualPeriod(
        id: json['id'] as int,
        start: parseHealthDate(json['start_date'] as String),
        end: json['end_date'] == null
            ? null
            : parseHealthDate(json['end_date'] as String),
        dates: (json['bleeding_dates'] as List)
            .map((day) => parseHealthDate(day as String))
            .toList(),
      );
  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'start_date': dateKey(start),
        'end_date': end == null ? null : dateKey(end!),
        'bleeding_dates': dates.map(dateKey).toList(),
      };
  bool hasDate(DateTime date) => dates.contains(healthDate(date));
}

class HealthDay {
  const HealthDay(
      {required this.date,
      this.flow = 'none',
      this.pain = 0,
      this.symptoms = const [],
      this.mood = '',
      this.spotting = false,
      this.notes = ''});
  final DateTime date;
  final String flow;
  final int pain;
  final List<String> symptoms;
  final String mood;
  final bool spotting;
  final String notes;
  factory HealthDay.fromJson(Map<String, dynamic> json) => HealthDay(
        date: parseHealthDate(json['date'] as String),
        flow: json['flow'] as String,
        pain: json['pain'] as int,
        symptoms: (json['symptoms'] as List).cast<String>(),
        mood: json['mood'] as String,
        spotting: json['spotting'] as bool,
        notes: json['notes'] as String,
      );
  Map<String, dynamic> toJson() => {
        'date': dateKey(date),
        'flow': flow,
        'pain': pain,
        'symptoms': symptoms,
        'mood': mood,
        'spotting': spotting,
        'notes': notes,
      };
}

enum HealthDateType { ordinary, period, predictedPeriod, fertile, ovulation }

class HealthData {
  const HealthData(
      {this.settings = const HealthSettings(),
      this.periods = const [],
      this.days = const []});
  final HealthSettings settings;
  final List<MenstrualPeriod> periods;
  final List<HealthDay> days;
  factory HealthData.fromJson(Map<String, dynamic> json) => HealthData(
        settings:
            HealthSettings.fromJson(json['settings'] as Map<String, dynamic>),
        periods: (json['periods'] as List)
            .map((row) => MenstrualPeriod.fromJson(row as Map<String, dynamic>))
            .toList(),
        days: (json['days'] as List)
            .map((row) => HealthDay.fromJson(row as Map<String, dynamic>))
            .toList(),
      );
  List<MenstrualPeriod> get sortedPeriods =>
      [...periods]..sort((a, b) => a.start.compareTo(b.start));
  MenstrualPeriod? get latest =>
      sortedPeriods.isEmpty ? null : sortedPeriods.last;
  MenstrualPeriod? get ongoing => periods.where((p) => p.ongoing).firstOrNull;
  List<int> get cycleLengths {
    final sorted = sortedPeriods;
    return [
      for (var i = 1; i < sorted.length; i++)
        if (!sorted[i - 1].ongoing)
          sorted[i].start.difference(sorted[i - 1].start).inDays
    ];
  }

  List<int> get periodLengths => sortedPeriods
      .where((p) => !p.ongoing)
      .map((p) => p.dates.length)
      .toList();
  MenstrualPeriod? periodAt(DateTime date) =>
      periods.where((p) => p.hasDate(date)).firstOrNull;
  MenstrualPeriod? cycleAt(DateTime date) => sortedPeriods
      .where((p) =>
          !date.isBefore(p.start) && (p.end == null || !date.isAfter(p.end!)))
      .lastOrNull;
  HealthDay? dayAt(DateTime date) =>
      days.where((day) => day.date == healthDate(date)).firstOrNull;
}

int typicalLength(List<int> values) {
  final recent = values.skip(values.length > 6 ? values.length - 6 : 0).toList()
    ..sort();
  final middle = recent.length ~/ 2;
  return recent.length.isOdd
      ? recent[middle]
      : ((recent[middle - 1] + recent[middle]) / 2).round();
}

class HealthPrediction {
  HealthPrediction(this.data, DateTime today) : today = healthDate(today);
  final HealthData data;
  final DateTime today;
  int? get cycleLength => data.cycleLengths.length >= 3
      ? typicalLength(data.cycleLengths)
      : data.settings.cycleLength;
  int? get periodLength => data.periodLengths.isNotEmpty
      ? typicalLength(data.periodLengths)
      : data.settings.periodLength;
  DateTime? get nextStart =>
      data.settings.paused || data.latest == null || cycleLength == null
          ? null
          : data.latest!.start.add(Duration(days: cycleLength!));
  DateTime? get nextEnd => nextStart == null || periodLength == null
      ? null
      : nextStart!.add(Duration(days: periodLength! - 1));
  // ponytail: calendar-only estimate; add measured ovulation data if needed.
  DateTime? get ovulation =>
      nextStart == null ? null : nextStart!.subtract(const Duration(days: 14));
  DateTime? get fertileStart => ovulation?.subtract(const Duration(days: 5));
  bool get variableCycles {
    final recent = data.cycleLengths.reversed.take(6).toList()..sort();
    // A display hint about variation, not a medical abnormality threshold.
    return recent.length >= 3 && recent.last - recent.first > 7;
  }

  String get basis => data.cycleLengths.length >= 3
      ? '参考最近 ${data.cycleLengths.length.clamp(3, 6)} 个已记录周期的中位数${variableCycles ? '；周期差异较大，预测参考性有限' : ''}'
      : '基于你填写的周期估计；历史记录较少';

  HealthDateType typeAt(DateTime value) {
    final date = healthDate(value);
    if (data.periodAt(date) != null) return HealthDateType.period;
    if (nextStart == null || date.isBefore(today))
      return HealthDateType.ordinary;
    if (nextEnd != null &&
        !date.isBefore(nextStart!) &&
        !date.isAfter(nextEnd!)) return HealthDateType.predictedPeriod;
    if (ovulation != null &&
        date == ovulation &&
        !date.isBefore(data.latest!.start)) return HealthDateType.ovulation;
    if (fertileStart != null &&
        !date.isBefore(fertileStart!) &&
        !date.isAfter(ovulation!) &&
        !date.isBefore(data.latest!.start)) return HealthDateType.fertile;
    return HealthDateType.ordinary;
  }
}

class FemaleHealthStore {
  final _api = ApiClient.instance;
  Future<HealthData> load() async => HealthData.fromJson(
      await _api.request('GET', 'female-health') as Map<String, dynamic>);
  Future<void> saveSettings(HealthSettings value) async {
    await _api.request('PUT', 'female-health/settings', body: value.toJson());
  }

  Future<void> savePeriod(MenstrualPeriod value) async {
    await _api.request('PUT', 'female-health/periods', body: value.toJson());
  }

  Future<void> deletePeriod(int id) async {
    await _api.request('DELETE', 'female-health/periods', query: {'id': '$id'});
  }

  Future<void> saveDay(HealthDay value) async {
    await _api.request('PUT', 'female-health/days', body: value.toJson());
  }

  Future<void> deleteDay(DateTime date) async {
    await _api.request('DELETE', 'female-health/days',
        query: {'date': dateKey(date)});
  }

  Future<void> clear({required bool resetSettings}) async {
    await _api.request('DELETE', 'female-health',
        query: {'reset_settings': '$resetSettings'});
  }
}
