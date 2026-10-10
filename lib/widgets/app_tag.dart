import 'package:flutter/material.dart';

import '../theme.dart';

/// 统一状态标签（圆角胶囊）：客户标签 / 项目状态 / 记录状态等。
///
/// 统一规约：圆角 [AppRadius.sheet]（20）、内边距 8/3、字号 12 w600，
/// 浅底 + 同色文字（[solid] 为 true 时实心 + 白字）。
class AppTag extends StatelessWidget {
  /// 标签文案。
  final String label;

  /// 标签主色，默认品牌蓝。
  final Color color;

  /// 是否实心显示。
  final bool solid;

  const AppTag({
    super.key,
    required this.label,
    this.color = AppTheme.primary,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sheet),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppFont.tag,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: solid ? Colors.white : color,
        ),
      ),
    );
  }
}

/// 统一筛选按钮：替代散落在各页自定义样式的 ChoiceChip / FilterChip / ActionChip。
///
/// 视觉与 [RangeFilterBar] 内的筛选按钮完全一致：纯文字、无图标、
/// 圆角 16、内边距 12/6、字号 12。
class AppFilterChip extends StatelessWidget {
  /// 按钮文案。
  final String label;

  /// 是否选中。
  final bool selected;

  /// 点击回调。
  final VoidCallback onTap;

  /// 选中态填充色与未选中浅底色，默认品牌蓝，可按语义传入（如橙色未对账）。
  final Color color;

  const AppFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color = AppTheme.primary,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sheet),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? color
              : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.sheet),
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: TextStyle(
            fontSize: AppFont.tag,
            height: 1.2,
            color: selected ? Colors.white : AppTheme.textMain,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
