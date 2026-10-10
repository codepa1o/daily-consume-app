import 'dart:async';

import 'package:flutter/material.dart';

import 'data/travel_planner.dart';
import 'travel_export.dart';
import 'travel_map.dart';

const _resultGreen = Color(0xff64765a);
const _resultMuted = Color(0xff70756b);
const _resultSurface = Color(0xfffffefa);

class TravelResultView extends StatefulWidget {
  const TravelResultView({
    super.key,
    required this.plan,
    required this.onBack,
    required this.onNewPlan,
  });

  final TravelPlan plan;
  final VoidCallback onBack;
  final VoidCallback onNewPlan;

  @override
  State<TravelResultView> createState() => _TravelResultViewState();
}

class _TravelResultViewState extends State<TravelResultView> {
  final _overviewKey = GlobalKey();
  final _weatherKey = GlobalKey();
  late TravelPlan _plan;
  late List<GlobalKey> _dayKeys;
  final Map<String, Future<String?>> _photoRequests = {};
  bool _editing = false;
  int _mapDay = -1;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan.copy();
    _dayKeys = List.generate(_plan.days.length, (_) => GlobalKey());
    unawaited(_hydrateMealLocations());
  }

  @override
  void didUpdateWidget(covariant TravelResultView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plan != widget.plan) {
      _plan = widget.plan.copy();
      _dayKeys = List.generate(_plan.days.length, (_) => GlobalKey());
    }
  }

  List<GlobalKey> get _exportKeys => [
        _overviewKey,
        ..._dayKeys,
        if (_plan.weather.isNotEmpty) _weatherKey,
      ];

  void _beginEdit() => setState(() {
        _plan = _plan.copy();
        _editing = true;
      });

  void _cancelEdit() => setState(() {
        _plan = widget.plan.copy();
        _editing = false;
        _dayKeys = List.generate(_plan.days.length, (_) => GlobalKey());
      });

  void _saveEdit() => setState(() => _editing = false);

  void _changeAttraction(
      int dayIndex, int attractionIndex, String key, Object? value) {
    final attractions = _plan.data['days'][dayIndex]['attractions'] as List;
    final attraction = attractions[attractionIndex] as Map<String, dynamic>;
    attraction[key] = value;
  }

  void _deleteAttraction(int dayIndex, int attractionIndex) => setState(() {
        final attractions = _plan.data['days'][dayIndex]['attractions'] as List;
        attractions.removeAt(attractionIndex);
      });

  void _moveAttraction(int dayIndex, int index, int delta) => setState(() {
        final attractions = _plan.data['days'][dayIndex]['attractions'] as List;
        final destination = index + delta;
        if (destination < 0 || destination >= attractions.length) return;
        final item = attractions.removeAt(index);
        attractions.insert(destination, item);
      });

  Future<void> _export(bool asPdf) async {
    if (_editing) return;
    try {
      if (asPdf) {
        await TravelExport.sharePdf(_plan.city, _exportKeys);
      } else {
        await TravelExport.shareImages(_plan.city, _exportKeys);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('导出失败：$error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = _plan.days;
    final allPoints = TravelMapPoint.fromPlan(_plan);
    final visiblePoints = _mapDay < 0
        ? allPoints
        : allPoints.where((point) => point.dayIndex == _mapDay).toList();
    return Column(children: [
      _toolbar(),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RepaintBoundary(key: _overviewKey, child: _overviewCard()),
                    const SizedBox(height: 14),
                    _mapCard(allPoints, visiblePoints, days),
                    if (days.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const _SectionHeading(
                          icon: Icons.view_day_outlined, title: '每日行程'),
                      const SizedBox(height: 8),
                      for (var index = 0; index < days.length; index++) ...[
                        RepaintBoundary(
                          key: _dayKeys[index],
                          child: _dayCard(index, days[index]),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                    if (_plan.weather.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const _SectionHeading(
                          icon: Icons.cloud_outlined, title: '天气信息'),
                      const SizedBox(height: 8),
                      RepaintBoundary(key: _weatherKey, child: _weatherCards()),
                    ],
                  ]),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _toolbar() => Material(
        color: _resultSurface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _editing ? _cancelEdit : widget.onBack,
                icon: Icon(_editing ? Icons.close : Icons.arrow_back),
                label: Text(_editing ? '取消修改' : '返回表单'),
              ),
              Wrap(spacing: 8, children: [
                if (_editing)
                  FilledButton.icon(
                    onPressed: _saveEdit,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存修改'),
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: _beginEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('编辑行程'),
                  ),
                  PopupMenuButton<bool>(
                    tooltip: '导出行程',
                    onSelected: _export,
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: false, child: Text('导出为图片')),
                      PopupMenuItem(value: true, child: Text('导出为 PDF')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xffd8d8d0)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child:
                          const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.download_outlined, size: 18),
                        SizedBox(width: 6),
                        Text('导出行程'),
                      ]),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: widget.onNewPlan,
                    icon: const Icon(Icons.add_road_rounded),
                    label: const Text('新规划'),
                  ),
                ],
              ]),
            ],
          ),
        ),
      );

  Widget _overviewCard() {
    final budget = _plan.budget;
    return Card(
      color: _resultSurface,
      elevation: 0,
      shape: _cardShape,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_plan.city}旅行计划',
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('${_plan.startDate} 至 ${_plan.endDate} · ${_plan.days.length} 天',
              style: const TextStyle(color: _resultMuted)),
          if (_plan.suggestions.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('整体建议', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(_plan.suggestions, style: const TextStyle(height: 1.55)),
          ],
          if (budget != null) ...[
            const Divider(height: 28),
            Wrap(spacing: 12, runSpacing: 10, children: [
              _BudgetValue('景点门票', budget['total_attractions']),
              _BudgetValue('酒店住宿', budget['total_hotels']),
              _BudgetValue('餐饮费用', budget['total_meals']),
              _BudgetValue('交通费用', budget['total_transportation']),
              _BudgetValue('预估总费用', budget['total'], total: true),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _mapCard(
    List<TravelMapPoint> allPoints,
    List<TravelMapPoint> visiblePoints,
    List<TravelJson> days,
  ) =>
      Card(
        color: _resultSurface,
        elevation: 0,
        shape: _cardShape,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                child: _SectionHeading(icon: Icons.map_outlined, title: '行程地图'),
              ),
              DropdownButton<int>(
                value: _mapDay,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('全程地图')),
                  for (var index = 0; index < days.length; index++)
                    DropdownMenuItem(
                        value: index, child: Text('第 ${index + 1} 天')),
                ],
                onChanged: (value) => setState(() => _mapDay = value ?? -1),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 330,
              child: visiblePoints.isEmpty
                  ? const _EmptyMapMessage()
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: TravelMapWidget(
                        key: ValueKey('map-$_mapDay-${visiblePoints.length}'),
                        points: visiblePoints,
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 14, children: [
              for (final entry in const [
                ('hotel', '住宿'),
                ('attraction', '景点'),
                ('meal', '餐饮'),
              ])
                _LegendItem(type: entry.$1, label: entry.$2),
              Text('${visiblePoints.length} 个地点',
                  style: const TextStyle(color: _resultMuted, fontSize: 12)),
            ]),
            if (_mapDay >= 0 && allPoints.isNotEmpty)
              Text('全程共 ${allPoints.length} 个地点',
                  style: const TextStyle(color: _resultMuted, fontSize: 12)),
          ]),
        ),
      );

  Widget _dayCard(int dayIndex, TravelJson day) {
    final attractions =
        day['attractions'] is List ? day['attractions'] as List : const [];
    final meals = day['meals'] is List ? day['meals'] as List : const [];
    final hotel = day['hotel'] is Map ? travelJson(day['hotel']) : null;
    final date = day['date'] as String? ?? '';
    return Card(
      key: ValueKey('travel-day-$dayIndex'),
      color: _resultSurface,
      elevation: 0,
      shape: _cardShape,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0xffe9eee4),
                  borderRadius: BorderRadius.circular(12)),
              child: Text('${dayIndex + 1}',
                  style: const TextStyle(
                      color: _resultGreen, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text('第 ${dayIndex + 1} 天  $date',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16))),
          ]),
          if ((day['description'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(day['description'] as String,
                style: const TextStyle(height: 1.5)),
          ],
          const SizedBox(height: 10),
          _InfoLine(
              label: '交通方式', value: day['transportation'] as String? ?? '未提供'),
          _InfoLine(
              label: '住宿安排', value: day['accommodation'] as String? ?? '未提供'),
          if (attractions.isNotEmpty) ...[
            const Divider(height: 24),
            const _SectionHeading(
                icon: Icons.photo_camera_outlined, title: '景点安排'),
            const SizedBox(height: 8),
            for (var index = 0; index < attractions.length; index++)
              _attractionCard(
                  dayIndex, index, attractions[index] as Map<String, dynamic>),
          ],
          if (hotel != null) ...[
            const Divider(height: 24),
            const _SectionHeading(icon: Icons.hotel_outlined, title: '住宿推荐'),
            const SizedBox(height: 8),
            _hotelDetails(hotel),
          ],
          if (meals.isNotEmpty) ...[
            const Divider(height: 24),
            const _SectionHeading(
                icon: Icons.restaurant_outlined, title: '餐饮安排'),
            const SizedBox(height: 8),
            for (final item in meals)
              _mealLine(item is Map ? travelJson(item) : <String, dynamic>{}),
          ],
        ]),
      ),
    );
  }

  Widget _attractionCard(
      int dayIndex, int index, Map<String, dynamic> attraction) {
    final name = attraction['name'] as String? ?? '景点';
    final rating = attraction['rating'];
    final price = attraction['ticket_price'];
    return Card(
      key: ValueKey('attraction-$dayIndex-$name'),
      margin: const EdgeInsets.symmetric(vertical: 5),
      color: const Color(0xfffafaf6),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: SizedBox(
                width: 82, height: 82, child: _attractionPhoto(attraction)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              _editField(dayIndex, index, attraction, 'address', '地址',
                  minLines: 1),
              _editField(dayIndex, index, attraction, 'description', '介绍',
                  minLines: 2),
              Wrap(spacing: 12, children: [
                Text('建议游览 ${attraction['visit_duration'] ?? 0} 分钟',
                    style: const TextStyle(color: _resultMuted, fontSize: 12)),
                if (rating != null)
                  Text('评分 $rating',
                      style:
                          const TextStyle(color: _resultMuted, fontSize: 12)),
                if (price != null && price != 0)
                  Text('门票 ¥$price',
                      style:
                          const TextStyle(color: _resultMuted, fontSize: 12)),
              ]),
              if (_editing) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Text('游览分钟'),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 100,
                    child: TextFormField(
                      key: ValueKey('duration-$dayIndex-$index-$name'),
                      initialValue: '${attraction['visit_duration'] ?? 60}',
                      keyboardType: TextInputType.number,
                      onChanged: (value) => _changeAttraction(dayIndex, index,
                          'visit_duration', int.tryParse(value) ?? 0),
                      decoration: const InputDecoration(
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                      tooltip: '上移',
                      onPressed: index == 0
                          ? null
                          : () => _moveAttraction(dayIndex, index, -1),
                      icon: const Icon(Icons.arrow_upward, size: 18)),
                  IconButton(
                      tooltip: '下移',
                      onPressed: index >=
                              (travelJsonList(
                                          _plan.days[dayIndex]['attractions'])
                                      .length -
                                  1)
                          ? null
                          : () => _moveAttraction(dayIndex, index, 1),
                      icon: const Icon(Icons.arrow_downward, size: 18)),
                  IconButton(
                      tooltip: '删除',
                      onPressed: () => _deleteAttraction(dayIndex, index),
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.redAccent, size: 18)),
                ]),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _editField(
    int dayIndex,
    int attractionIndex,
    Map<String, dynamic> attraction,
    String key,
    String label, {
    int minLines = 1,
  }) {
    final value = attraction[key] as String? ?? '';
    if (!_editing) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('$label：$value',
            style: const TextStyle(
                color: _resultMuted, fontSize: 12, height: 1.4)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TextFormField(
        key: ValueKey('$key-$dayIndex-$attractionIndex-${attraction['name']}'),
        initialValue: value,
        minLines: minLines,
        maxLines: minLines == 1 ? 2 : 4,
        onChanged: (text) =>
            _changeAttraction(dayIndex, attractionIndex, key, text),
        decoration: InputDecoration(
            labelText: label,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 9, vertical: 8)),
      ),
    );
  }

  Widget _attractionPhoto(Map<String, dynamic> attraction) {
    final photos = attraction['photos'];
    final knownUrl = attraction['image_url'] as String? ??
        (photos is List && photos.isNotEmpty ? photos.first as String? : null);
    if (knownUrl != null && knownUrl.isNotEmpty) return _networkPhoto(knownUrl);
    final name = attraction['name'] as String? ?? '';
    if (name.isEmpty) return const _PhotoPlaceholder();
    final future = _photoRequests.putIfAbsent(
      name,
      () => TravelPlannerApi.instance
          .photoUrl(name)
          .catchError((Object _) => null),
    );
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) => snapshot.data == null
          ? const _PhotoPlaceholder()
          : _networkPhoto(snapshot.data!),
    );
  }

  Widget _networkPhoto(String url) => Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _PhotoPlaceholder(),
      );

  Widget _hotelDetails(TravelJson hotel) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xfffafaf6),
            borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(hotel['name'] as String? ?? '住宿推荐',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if ((hotel['address'] as String? ?? '').isNotEmpty)
            Text('地址：${hotel['address']}'),
          Wrap(spacing: 12, runSpacing: 4, children: [
            if ((hotel['type'] as String? ?? '').isNotEmpty)
              Text('类型：${hotel['type']}'),
            if ((hotel['price_range'] as String? ?? '').isNotEmpty)
              Text('价格：${hotel['price_range']}'),
            if ((hotel['rating'] as String? ?? '').isNotEmpty)
              Text('评分：${hotel['rating']}'),
          ]),
          if ((hotel['distance'] as String? ?? '').isNotEmpty)
            Text('距离：${hotel['distance']}'),
          if (hotel['estimated_cost'] != null)
            Text('预估每晚：¥${hotel['estimated_cost']}'),
        ]),
      );

  Widget _mealLine(TravelJson meal) {
    final type = meal['type'] as String? ?? '';
    final label = switch (type) {
      'breakfast' => '早餐',
      'lunch' => '午餐',
      'dinner' => '晚餐',
      'snack' => '加餐',
      _ => type.isEmpty ? '餐饮' : type,
    };
    final name = meal['name'] as String? ?? '未安排';
    final desc = meal['description'] as String? ?? '';
    final cost = meal['estimated_cost'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 42,
            child: Text(label, style: const TextStyle(color: _resultMuted))),
        Expanded(child: Text('$name${desc.isEmpty ? '' : ' · $desc'}')),
        if (cost != null)
          Text('¥$cost', style: const TextStyle(color: _resultMuted)),
      ]),
    );
  }

  Future<void> _hydrateMealLocations() async {
    final days = _plan.data['days'];
    if (days is! List) return;
    final missingNames = <String>{};
    for (final dayValue in days) {
      if (dayValue is! Map) continue;
      final meals = dayValue['meals'];
      if (meals is! List) continue;
      for (final mealValue in meals) {
        if (mealValue is! Map) continue;
        final name = mealValue['name'] as String? ?? '';
        final location = travelJson(mealValue['location']);
        if (name.trim().isNotEmpty &&
            (location['longitude'] == null || location['latitude'] == null)) {
          missingNames.add(name);
        }
      }
    }
    if (missingNames.isEmpty) return;

    var changed = false;
    for (final name in missingNames) {
      try {
        final candidates = await TravelPlannerApi.instance.searchPois(
          name,
          _plan.city,
          sourceRole: 'food',
        );
        if (candidates.isEmpty) continue;
        final normalizedName =
            name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
        final candidate = candidates.firstWhere(
          (row) =>
              (row['name'] as String? ?? '')
                  .replaceAll(RegExp(r'\s+'), '')
                  .toLowerCase() ==
              normalizedName,
          orElse: () => candidates.first,
        );
        final location = travelJson(candidate['location']);
        if (location['longitude'] == null || location['latitude'] == null)
          continue;
        for (final dayValue in days) {
          if (dayValue is! Map || dayValue['meals'] is! List) continue;
          for (final mealValue in dayValue['meals'] as List) {
            if (mealValue is! Map) continue;
            final existingLocation = travelJson(mealValue['location']);
            if (existingLocation['longitude'] != null &&
                existingLocation['latitude'] != null) {
              continue;
            }
            if ((mealValue['name'] as String? ?? '') == name) {
              mealValue['location'] = location;
              if ((mealValue['address'] as String? ?? '').isEmpty) {
                mealValue['address'] = candidate['address'] ?? '';
              }
              changed = true;
            }
          }
        }
      } catch (_) {
        // 地图补点失败时保留文字行程，其他地点继续显示。
      }
    }
    if (changed && mounted) setState(() {});
  }

  Widget _weatherCards() => Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final item in _plan.weather)
            SizedBox(
              width: 230,
              child: Card(
                color: _resultSurface,
                elevation: 0,
                shape: _cardShape,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item['date'] as String? ?? '',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                            '☀️ 白天  ${item['day_weather'] ?? ''} ${item['day_temp'] ?? ''}°C'),
                        Text(
                            '🌙 夜间  ${item['night_weather'] ?? ''} ${item['night_temp'] ?? ''}°C'),
                        Text(
                            '💨 ${item['wind_direction'] ?? ''} ${item['wind_power'] ?? ''}',
                            style: const TextStyle(
                                color: _resultMuted, fontSize: 12)),
                      ]),
                ),
              ),
            ),
        ],
      );
}

const _cardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(18)),
  side: BorderSide(color: Color(0xffe8e7df)),
);

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, color: _resultGreen, size: 19),
        const SizedBox(width: 7),
        Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ]);
}

class _BudgetValue extends StatelessWidget {
  const _BudgetValue(this.label, this.value, {this.total = false});
  final String label;
  final Object? value;
  final bool total;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 118),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: total ? const Color(0xffe9eee4) : const Color(0xfff4f4ee),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(color: _resultMuted, fontSize: 11)),
          const SizedBox(height: 4),
          Text('¥${value ?? 0}',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: total ? _resultGreen : null)),
        ]),
      );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 72,
              child: Text(label, style: const TextStyle(color: _resultMuted))),
          Expanded(child: Text(value)),
        ]),
      );
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xffe9eee4),
        child: Center(
            child:
                Icon(Icons.landscape_outlined, color: _resultGreen, size: 30)),
      );
}

class _EmptyMapMessage extends StatelessWidget {
  const _EmptyMapMessage();

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('当前行程没有可定位的地点', style: TextStyle(color: _resultMuted)),
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.type, required this.label});
  final String type;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      'hotel' => const Color(0xff0f766e),
      'meal' => const Color(0xfff59e0b),
      _ => const Color(0xff1677ff),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: _resultMuted, fontSize: 12)),
    ]);
  }
}
