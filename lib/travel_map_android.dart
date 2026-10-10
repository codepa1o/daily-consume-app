import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'data/travel_planner.dart';
import 'travel_map_html.dart';

class TravelMapWidget extends StatefulWidget {
  const TravelMapWidget({super.key, required this.points});
  final List<TravelMapPoint> points;

  @override
  State<TravelMapWidget> createState() => _TravelMapWidgetState();
}

class _TravelMapWidgetState extends State<TravelMapWidget> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadHtmlString(buildTravelMapHtml(widget.points));
  }

  @override
  void didUpdateWidget(covariant TravelMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.loadHtmlString(buildTravelMapHtml(widget.points));
  }

  @override
  Widget build(BuildContext context) {
    if (amapWebKey.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('地图暂不可用。构建时请配置 AMAP_WEB_JS_KEY。'),
        ),
      );
    }
    return WebViewWidget(controller: _controller);
  }
}
