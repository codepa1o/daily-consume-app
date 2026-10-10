import 'dart:convert';

import 'api_client.dart';

typedef TravelJson = Map<String, dynamic>;

TravelJson travelJson(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<TravelJson> travelJsonList(Object? value) => value is List
    ? value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList()
    : <TravelJson>[];

class TravelPlan {
  TravelPlan(TravelJson data) : data = _copy(data);

  final TravelJson data;

  static TravelJson _copy(TravelJson value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  String get city => data['city'] as String? ?? '';
  String get startDate => data['start_date'] as String? ?? '';
  String get endDate => data['end_date'] as String? ?? '';
  String get suggestions => data['overall_suggestions'] as String? ?? '';
  List<TravelJson> get days => travelJsonList(data['days']);
  List<TravelJson> get weather => travelJsonList(data['weather_info']);
  TravelJson? get budget =>
      data['budget'] is Map ? travelJson(data['budget']) : null;

  TravelPlan copy() => TravelPlan(data);
}

class TravelMapPoint {
  const TravelMapPoint({
    required this.name,
    required this.type,
    required this.dayIndex,
    required this.order,
    required this.longitude,
    required this.latitude,
    this.address = '',
    this.description = '',
  });

  final String name;
  final String type;
  final int dayIndex;
  final int order;
  final double longitude;
  final double latitude;
  final String address;
  final String description;

  String get typeLabel => switch (type) {
        'hotel' => '住宿',
        'meal' => '餐饮',
        _ => '景点',
      };

  static List<TravelMapPoint> fromPlan(TravelPlan plan) {
    final points = <TravelMapPoint>[];
    for (var dayIndex = 0; dayIndex < plan.days.length; dayIndex++) {
      final day = plan.days[dayIndex];
      final hotel = travelJson(day['hotel']);
      _add(points, hotel, 'hotel', dayIndex, 0);

      final attractions = travelJsonList(day['attractions']);
      final meals = travelJsonList(day['meals']);
      for (var index = 0; index < attractions.length; index++) {
        _add(points, attractions[index], 'attraction', dayIndex,
            20 + index * 20);
      }
      for (final meal in meals) {
        final type = meal['type'] as String? ?? '';
        final order = switch (type) {
          'breakfast' => 10,
          'lunch' => 40,
          'snack' => 80,
          'dinner' => 90,
          _ => 70,
        };
        _add(points, meal, 'meal', dayIndex, order);
      }
    }
    return points;
  }

  static void _add(
    List<TravelMapPoint> result,
    TravelJson row,
    String type,
    int dayIndex,
    int order,
  ) {
    final location = travelJson(row['location']);
    final longitude = (location['longitude'] as num?)?.toDouble();
    final latitude = (location['latitude'] as num?)?.toDouble();
    final name = row['name'] as String? ?? '';
    if (name.isEmpty || longitude == null || latitude == null) return;
    if (longitude < -180 ||
        longitude > 180 ||
        latitude < -90 ||
        latitude > 90) {
      return;
    }
    result.add(TravelMapPoint(
      name: name,
      type: type,
      dayIndex: dayIndex,
      order: order,
      longitude: longitude,
      latitude: latitude,
      address: row['address'] as String? ?? '',
      description: row['description'] as String? ?? '',
    ));
  }
}

class TravelPlannerApi {
  TravelPlannerApi._();
  static final instance = TravelPlannerApi._();
  final _api = ApiClient.instance;

  Future<TravelPlan> generate(TravelJson request) async {
    final response = travelJson(await _api.request(
      'POST',
      'travel/plan',
      body: request,
      timeout: const Duration(minutes: 10, seconds: 30),
    ));
    final data = response['data'];
    if (response['success'] != true || data is! Map) {
      throw ApiException(response['message'] as String? ?? '行程生成失败');
    }
    return TravelPlan(travelJson(data));
  }

  Future<List<TravelJson>> searchPois(
    String keywords,
    String city, {
    String sourceRole = 'food',
  }) async {
    final response = travelJson(await _api.request(
      'GET',
      'travel/poi/search',
      query: {'keywords': keywords, 'city': city, 'source_role': sourceRole},
    ));
    return travelJsonList(response['data']);
  }

  Future<TravelJson> poiDetail(String poiId) async => travelJson(
        await _api.request('GET', 'travel/poi/detail/$poiId'),
      );

  Future<String?> photoUrl(String name) async {
    final response = travelJson(await _api.request(
      'GET',
      'travel/poi/photo',
      query: {'name': name},
    ));
    final data = travelJson(response['data']);
    return data['photo_url'] as String?;
  }

  Future<List<TravelJson>> weather(String city) async => travelJsonList(
        travelJson(await _api.request(
          'GET',
          'travel/map/weather',
          query: {'city': city},
        ))['data'],
      );

  Future<TravelJson> route(TravelJson request) async => travelJson(
        travelJson(await _api.request('POST', 'travel/map/route',
            body: request))['data'],
      );
}
