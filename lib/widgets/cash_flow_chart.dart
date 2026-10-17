import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/app_database.dart' show dateKey;

const cashIncomeColor = Color(0xff64765a);
const cashExpenseColor = Color(0xffb4775d);

String _money(int cents) => '¥ ${(cents / 100).toStringAsFixed(2)}';

/// 同一日期的收支共用零轴和金额比例；支出是方向向下，不改变实际正金额。
class CashFlowPoint {
  const CashFlowPoint(
      {required this.date,
      required this.incomeCents,
      required this.expenseCents});
  final DateTime date;
  final int incomeCents, expenseCents;
  bool get isFuture => dateKey(date).compareTo(dateKey(DateTime.now())) > 0;
}

class CashFlowSummary extends StatelessWidget {
  const CashFlowSummary(
      {super.key, required this.incomeCents, required this.expenseCents});
  final int incomeCents, expenseCents;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = ((constraints.maxWidth + 12) / (140 * scale + 12))
            .floor()
            .clamp(1, 3);
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(spacing: 12, runSpacing: 16, children: [
          for (final item in [
            ('收入', incomeCents, cashIncomeColor),
            ('支出', expenseCents, cashExpenseColor),
            (
              '结余',
              incomeCents - expenseCents,
              Theme.of(context).colorScheme.onSurface
            )
          ])
            SizedBox(
                width: width,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.$1,
                          style: TextStyle(color: item.$3, fontSize: 12)),
                      const SizedBox(height: 5),
                      FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(_money(item.$2),
                              style: TextStyle(
                                  color: item.$3,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600))),
                    ])),
        ]);
      });
}

class CashFlowChart extends StatefulWidget {
  const CashFlowChart({super.key, required this.points});
  final List<CashFlowPoint> points;

  @override
  State<CashFlowChart> createState() => _CashFlowChartState();
}

class _CashFlowChartState extends State<CashFlowChart> {
  final _scroll = ScrollController();
  DateTime? _selected;

  @override
  void didUpdateWidget(covariant CashFlowChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.points.any((point) => point.date == _selected))
      _selected = null;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) return const Text('暂无收支记录');
    final maximum = widget.points.fold<int>(
        0,
        (value, point) =>
            math.max(value, math.max(point.incomeCents, point.expenseCents)));
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    final largest = TextPainter(
        text: TextSpan(
            text: '−${_money(maximum)}',
            style: DefaultTextStyle.of(context)
                .style
                .copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context))
      ..layout();
    // 每列按完整金额测量宽度；窄屏横向滚动，绝不隐藏金额或挤在相邻柱子上。
    final minWidth = math.max(96 * scale, largest.width + 20);
    final amountHeight = largest.height + 12;
    largest.dispose();
    final halfHeight = math.max(120 + 28 * scale, amountHeight + 24);
    final selected =
        widget.points.where((point) => point.date == _selected).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Wrap(spacing: 20, runSpacing: 6, children: [
        Text('↑ 收入', style: TextStyle(color: cashIncomeColor)),
        Text('↓ 支出', style: TextStyle(color: cashExpenseColor)),
        Text('中线为 ¥0', style: TextStyle(fontSize: 12)),
      ]),
      const SizedBox(height: 8),
      if (selected != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
                '${dateKey(selected.date)} · 收入 ${_money(selected.incomeCents)} · 支出 ${_money(selected.expenseCents)}')),
      LayoutBuilder(builder: (context, constraints) {
        final width =
            math.max(constraints.maxWidth, minWidth * widget.points.length);
        return Scrollbar(
            controller: _scroll,
            thumbVisibility: width > constraints.maxWidth,
            child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 14),
                child: SizedBox(
                    width: width,
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final point in widget.points)
                            SizedBox(
                                width: width / widget.points.length,
                                child: _column(context, point, maximum,
                                    halfHeight, amountHeight)),
                        ]))));
      }),
      const Text('按日期对齐，收入向上、支出向下；左右滑动可查看全部日期。',
          style: TextStyle(fontSize: 11)),
    ]);
  }

  Widget _column(BuildContext context, CashFlowPoint point, int maximum,
      double halfHeight, double labelHeight) {
    final selected = point.date == _selected;
    final future = point.isFuture;
    void select() {
      if (!future) setState(() => _selected = point.date);
    }

    double height(int value) =>
        maximum == 0 ? 0 : (halfHeight - labelHeight - 4) * value / maximum;
    Widget amount(int value, Color color, String sign) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(future ? '—' : '$sign${_money(value)}',
            maxLines: 1,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w600)));
    Widget bar(int value, Color color, bool top) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        width: 24,
        height: height(value),
        decoration: BoxDecoration(
            color: color.withValues(alpha: selected ? 1 : .75),
            borderRadius: BorderRadius.vertical(
                top: top ? const Radius.circular(5) : Radius.zero,
                bottom: top ? Radius.zero : const Radius.circular(5))));
    final label = '${point.date.month}/${point.date.day}';
    return Semantics(
        button: !future,
        onTap: future ? null : select,
        selected: selected,
        label:
            '${dateKey(point.date)}，${future ? '未到日期' : '收入${_money(point.incomeCents)}，支出${_money(point.expenseCents)}'}',
        excludeSemantics: true,
        child: Tooltip(
            message: future
                ? '${dateKey(point.date)} 未到日期'
                : '${dateKey(point.date)}\n收入 +${_money(point.incomeCents)}\n支出 -${_money(point.expenseCents)}\n结余 ${_money(point.incomeCents - point.expenseCents)}',
            child: MouseRegion(
                onEnter: (_) => select(),
                child: InkWell(
                    onTap: future ? null : select,
                    child: ColoredBox(
                        color: selected
                            ? cashIncomeColor.withValues(alpha: .08)
                            : Colors.transparent,
                        child: Column(children: [
                          SizedBox(
                              height: halfHeight,
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    amount(point.incomeCents, cashIncomeColor,
                                        '+'),
                                    bar(point.incomeCents, cashIncomeColor,
                                        true)
                                  ])),
                          Container(
                              height: 1, color: Theme.of(context).dividerColor),
                          SizedBox(
                              height: halfHeight,
                              child: Column(children: [
                                bar(point.expenseCents, cashExpenseColor,
                                    false),
                                amount(
                                    point.expenseCents, cashExpenseColor, '−')
                              ])),
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(label,
                                  style: TextStyle(
                                      color: future
                                          ? Theme.of(context).disabledColor
                                          : null,
                                      fontSize: 12))),
                        ]))))));
  }
}
