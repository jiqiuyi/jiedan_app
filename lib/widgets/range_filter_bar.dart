import 'package:flutter/material.dart';

import '../widgets/app_ui.dart';

/// 统一的时间范围筛选条（体验统一：收入统计页与收入记录页共用同一套视觉规范）。
///
/// 规约：
///  - 筛选项左对齐排列，各项间距统一（8），按内容自然宽度展示，不做等宽拉伸；
///  - 按钮上不放置任何图标，仅纯文字；
///  - 文字 12px、内边距紧凑（水平 12 / 垂直 6），保证「近12个月」「自定义」等较长文案完整显示；
///  - 一行放不下时自动换行（Wrap），不截断、不溢出。
class RangeFilterItem<T> {
  final T value;
  final String label;
  const RangeFilterItem(this.value, this.label);
}

class RangeFilterBar<T> extends StatelessWidget {
  final List<RangeFilterItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;

  const RangeFilterBar({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              RangeFilterChip(
                label: item.label,
                selected: item.value == value,
                onTap: () => onChanged(item.value),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单个筛选按钮：纯文字、无图标、主题色描边填充选中态
class RangeFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const RangeFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppFilterChip(label: label, selected: selected, onTap: onTap);
  }
}
