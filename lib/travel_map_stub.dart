import 'package:flutter/material.dart';

import 'data/travel_planner.dart';

class TravelMapWidget extends StatelessWidget {
  const TravelMapWidget({super.key, required this.points});
  final List<TravelMapPoint> points;

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('当前平台暂不支持地图显示'),
      );
}
