import 'package:flutter/material.dart';

import '../theme.dart';

/// 统一卡片容器：白底、圆角 14、细边框，与全局 cardTheme 完全一致。
///
/// 用于替代各页手写的 Container + BoxDecoration 卡片，消除圆角与边框差异。
class AppCard extends StatelessWidget {
  /// 卡片内容。
  final Widget child;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 外边距。
  final EdgeInsetsGeometry margin;

  /// 可选点击回调（提供后带水波纹）。
  final VoidCallback? onTap;

  /// 卡片底色。
  final Color color;
const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    this.onTap,
    this.color = AppTheme.card,
  });

  @override
  Widget build(BuildContext context) {
    final Widget body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(0xFFECEEF4)),
      ),
      child: child,
    );

    if (onTap == null) return Padding(padding: margin, child: body);

    return Padding(
      padding: margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: body,
        ),
      ),
    );
  }
}

/// 统一卡片内分割线：左右缩进 16、颜色与卡片边框一致。
///
/// 用于替代各页 `Divider(height: 1, indent: 14/16)` 等不一致写法。
class AppCardDivider extends StatelessWidget {
  /// 左右缩进（默认 16）。
  final double indent;
const AppCardDivider({super.key, this.indent = 16});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: indent,
      endIndent: indent,
      color: AppTheme.divider,
    );
  }
}
