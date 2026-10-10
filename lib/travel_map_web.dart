import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'data/travel_planner.dart';
import 'travel_map_html.dart';

int _nextTravelMapId = 0;

class TravelMapWidget extends StatefulWidget {
  const TravelMapWidget({super.key, required this.points});
  final List<TravelMapPoint> points;

  @override
  State<TravelMapWidget> createState() => _TravelMapWidgetState();
}

class _TravelMapWidgetState extends State<TravelMapWidget> {
  late final String _viewType;
  late final web.HTMLIFrameElement _frame;

  @override
  void initState() {
    super.initState();
    _viewType = 'travel-map-${_nextTravelMapId++}';
    _frame = web.HTMLIFrameElement()
      ..setAttribute('srcdoc', buildTravelMapHtml(widget.points))
      ..setAttribute('title', '旅游行程地图')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0';
    ui.platformViewRegistry.registerViewFactory(_viewType, (_) => _frame);
  }

  @override
  void didUpdateWidget(covariant TravelMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _frame.setAttribute('srcdoc', buildTravelMapHtml(widget.points));
  }

  @override
  Widget build(BuildContext context) {
    if (amapWebKey.isEmpty) {
      return const _MapNotConfigured();
    }
    return HtmlElementView(viewType: _viewType);
  }
}

class _MapNotConfigured extends StatelessWidget {
  const _MapNotConfigured();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('地图暂不可用。构建时请配置 AMAP_WEB_JS_KEY。'),
        ),
      );
}
