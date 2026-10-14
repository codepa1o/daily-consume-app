import 'package:flutter/material.dart';

const appCardPadding = EdgeInsets.all(16);
const appSectionGap = 16.0;

EdgeInsets appPagePadding(double width, {double bottom = 32}) {
  final horizontal = width >= 1050 ? 36.0 : 20.0;
  return EdgeInsets.fromLTRB(horizontal, 24, horizontal, bottom);
}

class AppPageList extends StatelessWidget {
  const AppPageList({
    super.key,
    required this.children,
    this.physics,
    this.bottom = 32,
  });

  final List<Widget> children;
  final ScrollPhysics? physics;
  final double bottom;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: appPagePadding(constraints.maxWidth, bottom: bottom),
          physics: physics,
          children: children,
        ),
      );
}

/// 根据实际内容宽度与系统字号排列同一组表单项。
class AppFormRow extends StatelessWidget {
  const AppFormRow({super.key, required this.children, this.breakpoint = 480});

  final List<Widget> children;
  final double breakpoint;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final horizontal = constraints.maxWidth >= breakpoint * scale;
          return Flex(
            direction: horizontal ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: horizontal
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0)
                  SizedBox(
                    width: horizontal ? appSectionGap : 0,
                    height: horizontal ? 0 : appSectionGap,
                  ),
                if (horizontal)
                  Expanded(child: children[index])
                else
                  children[index],
              ],
            ],
          );
        },
      );
}

/// 数值与单位共用文字基线，避免通过底部偏移量手工对齐。
class AppMetricValue extends StatelessWidget {
  const AppMetricValue({
    super.key,
    required this.value,
    required this.unit,
    required this.valueStyle,
    required this.unitStyle,
  });

  final String value, unit;
  final TextStyle valueStyle, unitStyle;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: valueStyle),
          ),
          const SizedBox(width: 6),
          Text(unit, style: unitStyle),
        ],
      );
}

class AppDateNavigator extends StatelessWidget {
  const AppDateNavigator({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onPrevious,
    required this.onNext,
    required this.onChoose,
    required this.onToday,
    this.isToday = false,
  });

  final String title, subtitle;
  final bool isToday;
  final VoidCallback onPrevious, onChoose, onToday;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => Row(children: [
        IconButton(
            tooltip: '前一天',
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(
            child: Column(children: [
          InkWell(
              onTap: onChoose,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                      child: Text(title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontFamily: 'serif', fontSize: 18))))),
          Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                if (!isToday)
                  TextButton(
                      onPressed: onToday,
                      style: TextButton.styleFrom(
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4)),
                      child: const Text('今天')),
              ]),
        ])),
        IconButton(
            tooltip: '后一天',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right_rounded)),
      ]);
}
