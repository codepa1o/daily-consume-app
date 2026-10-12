import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'data/travel_cities.dart';

const _green = Color(0xff64765a);

class TravelCityField extends StatefulWidget {
  const TravelCityField(
      {super.key, required this.controller, this.enabled = true});

  final TextEditingController controller;
  final bool enabled;

  @override
  State<TravelCityField> createState() => _TravelCityFieldState();
}

class _TravelCityFieldState extends State<TravelCityField> {
  final _menu = MenuController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late Future<List<TravelCity>> _cities = loadTravelCities();
  String _query = '';
  String? _letter;

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen || !widget.enabled) return;
    setState(() {
      _query = '';
      _letter = null;
    });
    _menu.open();
  }

  void _select(TravelCity city) {
    widget.controller.value = TextEditingValue(
      text: city.name,
      selection: TextSelection.collapsed(offset: city.name.length),
    );
    _menu.close();
    _focus.unfocus();
  }

  void _resetScroll() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // Scaffold 会移除正文的键盘边距，从视图读取以正确限制菜单高度。
          final viewport = MediaQueryData.fromView(View.of(context));
          final height = viewport.size.height - viewport.viewInsets.bottom;
          return MenuAnchor(
            controller: _menu,
            childFocusNode: _focus,
            consumeOutsideTap: false,
            alignmentOffset: const Offset(0, 6),
            style: const MenuStyle(
              alignment: Alignment.bottomLeft,
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
              backgroundColor: WidgetStatePropertyAll(Color(0xfffffefa)),
            ),
            menuChildren: [
              SizedBox(
                width: math.min(constraints.maxWidth, 560),
                height: math.min(440, math.max(160, height * .55)),
                child: FutureBuilder<List<TravelCity>>(
                  future: _cities,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                          child: TextButton.icon(
                        onPressed: () =>
                            setState(() => _cities = loadTravelCities()),
                        icon: const Icon(Icons.refresh),
                        label: const Text('城市列表加载失败，点击重试'),
                      ));
                    }
                    final cities = snapshot.data;
                    if (cities == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return _panel(cities);
                  },
                ),
              ),
            ],
            builder: (context, controller, _) => TextFormField(
              key: const ValueKey('travel-city-input'),
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              textInputAction: TextInputAction.done,
              onTap: _open,
              onChanged: (value) {
                setState(() {
                  _query = value;
                  _letter = null;
                });
                if (!_menu.isOpen) _menu.open();
                _resetScroll();
              },
              onFieldSubmitted: (_) => _menu.close(),
              decoration: InputDecoration(
                labelText: '目的地城市',
                hintText: '搜索城市 / 拼音 / 首字母',
                prefixIcon: const Icon(Icons.location_city_outlined),
                suffixIcon: IconButton(
                  tooltip: '展开城市列表',
                  onPressed: widget.enabled
                      ? () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            _open();
                          }
                        }
                      : null,
                  icon: const Icon(Icons.expand_more),
                ),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入或选择目的地城市' : null,
            ),
          );
        },
      );

  Widget _panel(List<TravelCity> cities) {
    final letters = cities.map((city) => city.letter).toSet().toList()..sort();
    final results = cities
        .where((city) =>
            (_letter == null || city.letter == _letter) && city.matches(_query))
        .toList();
    final showHot = _query.trim().isEmpty && _letter == null;
    final groups = <String, List<TravelCity>>{};
    for (final city in results) {
      groups.putIfAbsent(city.letter, () => []).add(city);
    }
    // 用列表项按需构建，避免展开时一次创建所有城市按钮。
    final rows = <Widget Function()>[];
    if (showHot) {
      rows.add(() => Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('热门城市', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final name in travelHotCityNames)
                  ActionChip(
                    key: ValueKey('travel-hot-$name'),
                    backgroundColor: const Color(0xffe9eee4),
                    label: Text(name),
                    onPressed: () =>
                        _select(cities.firstWhere((city) => city.name == name)),
                  ),
              ]),
            ]),
          ));
    }
    for (final group in groups.entries) {
      rows.add(() => Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(group.key,
                style: const TextStyle(
                    color: _green, fontWeight: FontWeight.w700)),
          ));
      for (final city in group.value) {
        rows.add(() => ListTile(
              key: ValueKey('travel-city-${city.code}'),
              dense: true,
              title: Text(city.name),
              subtitle: Text(city.province),
              onTap: () => _select(city),
            ));
      }
    }
    return Column(children: [
      SizedBox(
        height: 42 + MediaQuery.textScalerOf(context).scale(14),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          children: [
            for (final letter in <String?>[null, ...letters])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: ChoiceChip(
                  key: ValueKey('travel-city-letter-${letter ?? 'all'}'),
                  label: Text(letter ?? '全部'),
                  selected: _letter == letter,
                  onSelected: (_) {
                    setState(() => _letter = letter);
                    _resetScroll();
                  },
                ),
              ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
          child: results.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(16),
                  child:
                      Text('没有匹配的城市，可直接输入目的地名称。', textAlign: TextAlign.center),
                ))
              : ListView.builder(
                  controller: _scroll,
                  itemCount: rows.length,
                  itemBuilder: (context, index) => rows[index](),
                )),
    ]);
  }
}
