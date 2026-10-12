import 'package:flutter/material.dart';
import 'widgets/travel_planning_icon.dart';
import 'package:flutter/services.dart';

import 'data/api_client.dart';
import 'data/travel_planner.dart';
import 'travel_result_view.dart';
import 'travel_planning_loading.dart';
import 'travel_city_field.dart';

const _travelPaper = Color(0xfff6f5ef);
const _travelSurface = Color(0xfffffefa);
const _travelInk = Color(0xff292c25);
const _travelMuted = Color(0xff70756b);
const _travelGreen = Color(0xff64765a);
const _travelSoftGreen = Color(0xffe9eee4);

class TravelPlannerPage extends StatefulWidget {
  const TravelPlannerPage({super.key});

  @override
  State<TravelPlannerPage> createState() => _TravelPlannerPageState();
}

class _TravelPlannerPageState extends State<TravelPlannerPage> {
  final _formKey = GlobalKey<FormState>();
  final _cityController = TextEditingController();
  final _extraController = TextEditingController();
  final _budgetController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;
  int _adults = 2;
  int _children = 0;
  int _elders = 0;
  String _transportation = '公共交通';
  String _accommodation = '经济型酒店';
  String _budgetLevel = 'standard';
  final Set<String> _preferences = {};
  bool _busy = false;
  bool _generationComplete = false;
  bool _generationFailed = false;
  TravelPlan? _plan;

  static const _transportOptions = [
    '公共交通',
    '地铁公交',
    '打车/网约车',
    '自驾',
    '租车自驾',
    '包车/私人司机',
    '高铁+市内交通',
    '飞机+市内交通',
    '骑行/步行',
    '混合交通',
    '无障碍交通优先',
  ];

  static const _accommodationOptions = [
    '经济型酒店',
    '舒适型酒店',
    '高端酒店',
    '豪华酒店',
    '亲子酒店',
    '民宿',
  ];

  static const _budgetOptions = {
    'limited': '节省',
    'standard': '标准',
    'comfortable': '舒适',
    'premium': '高端',
    'luxury': '奢华',
  };

  static const _preferenceOptions = [
    ('历史文化', '🏛️'),
    ('自然风光', '🏞️'),
    ('美食', '🍜'),
    ('购物', '🛍️'),
    ('艺术', '🎨'),
    ('休闲', '☕'),
    ('亲子友好', '🧸'),
    ('老人友好', '🧓'),
    ('小众路线', '🧭'),
    ('夜游', '🌃'),
    ('摄影打卡', '📷'),
    ('博物馆', '🏺'),
    ('城市漫步', '🚶'),
    ('户外徒步', '🥾'),
    ('主题乐园', '🎢'),
    ('避开人群', '🌿'),
  ];

  @override
  void dispose() {
    _cityController.dispose();
    _extraController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  int get _partyTotal => _adults + _children + _elders;

  String get _companionType {
    if (_children > 0) return 'family_with_children';
    if (_elders > 0) return 'family_with_elders';
    if (_adults == 1) return 'solo';
    if (_adults == 2) return 'couple';
    if (_adults > 2) return 'friends';
    return 'other';
  }

  int? get _travelDays {
    if (_startDate == null || _endDate == null) return null;
    return _endDate!.difference(_startDate!).inDays + 1;
  }

  Future<void> _pickTravelDates() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _startDate == null || _endDate == null
          ? null
          : DateTimeRange(start: _startDate!, end: _endDate!),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('zh', 'CN'),
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: '先选出发日期，再选返回日期 · 最多30天',
      saveText: '确认日期',
      selectableDayPredicate: (day, start, end) =>
          start == null ||
          end != null ||
          day.isBefore(start) ||
          day.difference(start).inDays < 30,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: _travelGreen,
                surface: _travelSurface,
              ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
            child: child!,
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.duration.inDays >= 30) {
      _showMessage('旅行天数不能超过 30 天');
      return;
    }
    setState(() {
      _startDate = picked.start;
      _endDate = picked.end;
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _generate() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    if (_startDate == null || _endDate == null) {
      _showMessage('请选择出发和结束日期');
      return;
    }
    final days = _travelDays!;
    if (days < 1 || days > 30) {
      _showMessage('旅行天数需要在 1 到 30 天之间');
      return;
    }
    if (_partyTotal < 1 || _partyTotal > 30) {
      _showMessage('同行总人数需要在 1 到 30 人之间');
      return;
    }

    final budgetText = _budgetController.text.trim();
    final budget = budgetText.isEmpty ? null : int.tryParse(budgetText);
    if (budgetText.isNotEmpty && (budget == null || budget < 0)) {
      _showMessage('预算请输入有效的整数金额');
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      _generationComplete = false;
      _generationFailed = false;
    });

    try {
      final plan = await TravelPlannerApi.instance.generate({
        'city': _cityController.text.trim(),
        'start_date': _dateKey(_startDate!),
        'end_date': _dateKey(_endDate!),
        'travel_days': days,
        'transportation': _transportation,
        'accommodation': _accommodation,
        'preferences': _preferences.toList(),
        'free_text_input': _extraController.text.trim(),
        'party': {
          'adults': _adults,
          'children': _children,
          'elders': _elders,
          'total': _partyTotal,
          'companion_type': _companionType,
        },
        'budget_constraint': {
          'amount': budget,
          'scope': 'total',
          'currency': 'CNY',
          'budget_level': _budgetLevel,
          'strictness': budget == null ? 'none' : 'soft',
        },
      });
      if (!mounted) return;
      setState(() => _generationComplete = true);
      // 等待进度条补满，再切换到行程结果。
      await Future<void>.delayed(const Duration(milliseconds: 650));
      if (!mounted) return;
      setState(() => _plan = plan);
    } catch (error) {
      if (!mounted) return;
      setState(() => _generationFailed = true);
      _showMessage(error is ApiException ? error.message : '行程生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _dateKey(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String _dateLabel(DateTime? date) {
    if (date == null) return '选择日期';
    return '${date.year}年${date.month}月${date.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      backgroundColor: _travelPaper,
      body: SafeArea(
        child: plan == null
            ? _buildForm()
            : TravelResultView(
                key: ValueKey('${plan.city}-${plan.startDate}-${plan.endDate}'),
                plan: plan,
                onBack: () => setState(() => _plan = null),
                onNewPlan: () => setState(() => _plan = null),
              ),
      ),
    );
  }

  Widget _buildForm() => Stack(
        children: [
          Form(
            key: _formKey,
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              return SingleChildScrollView(
                padding:
                    EdgeInsets.fromLTRB(wide ? 36 : 18, 26, wide ? 36 : 18, 36),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _pageHeading(),
                        const SizedBox(height: 20),
                        _sectionCard(
                          title: '目的地与日期',
                          icon: Icons.place_outlined,
                          child: Column(children: [
                            TravelCityField(
                              controller: _cityController,
                              enabled: !_busy,
                            ),
                            const SizedBox(height: 16),
                            _dateRangeButton(),
                          ]),
                        ),
                        const SizedBox(height: 14),
                        _sectionCard(
                          title: '同行与预算',
                          icon: Icons.groups_outlined,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 18,
                                  runSpacing: 12,
                                  children: [
                                    _CounterField(
                                        label: '成人',
                                        value: _adults,
                                        onChanged: (v) =>
                                            setState(() => _adults = v)),
                                    _CounterField(
                                        label: '儿童',
                                        value: _children,
                                        onChanged: (v) =>
                                            setState(() => _children = v)),
                                    _CounterField(
                                        label: '老人',
                                        value: _elders,
                                        onChanged: (v) =>
                                            setState(() => _elders = v)),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      child: Text('共 $_partyTotal 人',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Row(children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: _budgetController,
                                      keyboardType: TextInputType.number,
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: '总预算（元，可不填）',
                                        prefixText: '¥ ',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: _budgetLevel,
                                      decoration: const InputDecoration(
                                          labelText: '预算档位'),
                                      items: [
                                        for (final entry
                                            in _budgetOptions.entries)
                                          DropdownMenuItem(
                                              value: entry.key,
                                              child: Text(entry.value)),
                                      ],
                                      onChanged: (value) => setState(() =>
                                          _budgetLevel = value ?? 'standard'),
                                    ),
                                  ),
                                ]),
                              ]),
                        ),
                        const SizedBox(height: 14),
                        _sectionCard(
                          title: '出行偏好',
                          icon: Icons.route_outlined,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _dropdown(
                                  label: '交通方式',
                                  value: _transportation,
                                  values: _transportOptions,
                                  onChanged: (value) =>
                                      setState(() => _transportation = value),
                                ),
                                const SizedBox(height: 14),
                                _dropdown(
                                  label: '住宿偏好',
                                  value: _accommodation,
                                  values: _accommodationOptions,
                                  onChanged: (value) =>
                                      setState(() => _accommodation = value),
                                ),
                                const SizedBox(height: 16),
                                const Text('旅行兴趣',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    for (final (label, icon)
                                        in _preferenceOptions)
                                      FilterChip(
                                        label: Text('$icon $label'),
                                        selected: _preferences.contains(label),
                                        onSelected: (selected) => setState(() {
                                          if (selected) {
                                            _preferences.add(label);
                                          } else {
                                            _preferences.remove(label);
                                          }
                                        }),
                                        selectedColor: _travelSoftGreen,
                                      ),
                                  ],
                                ),
                              ]),
                        ),
                        const SizedBox(height: 14),
                        _sectionCard(
                          title: '额外要求',
                          icon: Icons.edit_note_rounded,
                          child: TextFormField(
                            controller: _extraController,
                            maxLines: 4,
                            maxLength: 2000,
                            decoration: const InputDecoration(
                              hintText: '例如：需要无障碍设施、对海鲜过敏、希望每天安排轻松一些…',
                              alignLabelWithHint: true,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _generate,
                            icon: const Icon(Icons.auto_awesome_rounded),
                            label:
                                Text(_generationFailed ? '重试生成行程' : '开始规划行程'),
                            style: FilledButton.styleFrom(
                              backgroundColor: _travelGreen,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              textStyle: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
          if (_busy)
            Positioned.fill(
              child: BlockSemantics(
                child: Stack(children: [
                  ModalBarrier(
                    color: Colors.black.withValues(alpha: .30),
                    dismissible: false,
                  ),
                  Center(
                    child: TravelPlanningLoading(
                      complete: _generationComplete,
                    ),
                  ),
                ]),
              ),
            ),
        ],
      );

  Widget _pageHeading() =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
              color: _travelSoftGreen, borderRadius: BorderRadius.circular(16)),
          child: const IconTheme(
              data: IconThemeData(color: _travelGreen),
              child: Center(child: TravelPlanningIcon())),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('旅行规划',
                style: TextStyle(
                    color: _travelInk,
                    fontSize: 24,
                    fontWeight: FontWeight.w700)),
            SizedBox(height: 4),
            Text('填写偏好，生成按天安排的旅行计划。', style: TextStyle(color: _travelMuted)),
          ]),
        ),
      ]);

  Widget _dateRangeButton() {
    final end = _endDate;
    final range = _startDate == null || end == null
        ? '选择出发和返回日期'
        : '${_dateLabel(_startDate)} — '
            '${_startDate!.year == end.year ? '${end.month}月${end.day}日' : _dateLabel(end)}'
            ' · 共$_travelDays天';
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const ValueKey('travel-date-range'),
        onPressed: _busy ? null : _pickTravelDates,
        icon: const Icon(Icons.calendar_month_outlined),
        label: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('旅行日期',
              style: const TextStyle(fontSize: 11, color: _travelMuted)),
          Text(range),
        ]),
        style: OutlinedButton.styleFrom(
          foregroundColor: _travelInk,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          side: const BorderSide(color: Color(0xffdeded5)),
        ),
      ),
    );
  }

  Widget _sectionCard(
          {required String title,
          required IconData icon,
          required Widget child}) =>
      Card(
        color: _travelSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xffe8e7df)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: _travelGreen, size: 20),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 16),
            child,
          ]),
        ),
      );

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> values,
    required ValueChanged<String> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final item in values)
            DropdownMenuItem(value: item, child: Text(item))
        ],
        onChanged: (item) {
          if (item != null) onChanged(item);
        },
      );
}

class _CounterField extends StatelessWidget {
  const _CounterField(
      {required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label),
        const SizedBox(width: 8),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value <= 0 ? null : () => onChanged(value - 1),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(width: 20, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value >= 20 ? null : () => onChanged(value + 1),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ]);
}
