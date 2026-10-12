import 'dart:convert';

import 'package:flutter/services.dart';

const travelHotCityNames = [
  '北京',
  '上海',
  '广州',
  '深圳',
  '成都',
  '重庆',
  '杭州',
  '西安',
  '南京',
  '武汉',
  '长沙',
  '厦门',
  '青岛',
  '三亚',
  '大理',
  '丽江',
];

class TravelCity {
  const TravelCity({
    required this.name,
    required this.fullName,
    required this.province,
    required this.pinyin,
    required this.initials,
    required this.code,
  });

  final String name;
  final String fullName;
  final String province;
  final String pinyin;
  final String initials;
  final String code;

  String get letter => pinyin[0].toUpperCase();

  bool matches(String query) {
    final normalized = query.toLowerCase().replaceAll(RegExp(r"[\s'’_-]"), '');
    return [name, fullName, province, pinyin, initials]
        .any((value) => value.contains(normalized));
  }
}

Future<List<TravelCity>> loadTravelCities() =>
    rootBundle.loadStructuredData('assets/travel_cities.json', (source) async {
      final data = jsonDecode(source) as Map<String, dynamic>;
      return (data['cities'] as List)
          .map((row) => TravelCity(
                name: row['name'] as String,
                fullName: row['fullName'] as String,
                province: row['province'] as String,
                pinyin: row['pinyin'] as String,
                initials: row['initials'] as String,
                code: row['code'] as String,
              ))
          .toList();
    });
