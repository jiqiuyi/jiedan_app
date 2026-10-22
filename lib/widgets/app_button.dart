import 'package:flutter/material.dart';

import '../theme.dart';

/// 统一按钮尺寸档位。
enum AppButtonSize {
  /// 大按钮：页面主操作，高 48 / 字号 16。
  large,

  /// 中按钮：次级操作与对话框动作，高 40 / 字号 14。
  medium,

  /// 小按钮：卡片内轻操作与行内文字按钮，高 32 / 字号 13。
  small,
}

/// 统一按钮类型。
enum AppButtonKind {
  /// 主操作：实心品牌色。
  primary,

  /// 次级操作：描边。
  secondary,

  /// 轻量操作：纯文字。
  ghost,

  /// 危险操作：实心警示色。
  danger,

  /// 危险操作（描边）：次要危险入口，如详情页底部删除。
  dangerOutline,

  /// 次要实心：品牌色浅底。
  tonal,
}

/// 全 App 统一按钮：消除胶囊 / 方形混用与高度、圆角、字号不统一。
///
/// 统一规约（以工程内主流样式为基准）：
///  - 圆角固定 [AppRadius.md]（12），不再出现 StadiumBorder 胶囊按钮；
///  - 高度：large 48 / medium 40 / small 32；
///  - 字号：large 16 / medium 14 / small 13，字重统一 w600；
///  - 主色 [AppTheme.primary]，危险操作 [AppTheme.danger]。
class AppButton extends StatelessWidget {
  /// 按钮文案。
  final String label;

  /// 可选前置图标。
  final IconData? icon;

  /// 点击回调，为 null 时按钮呈禁用态。
  final VoidCallback? onPressed;

  /// 按钮类型。
  final AppButtonKind kind;

  /// 尺寸档位。
  final AppButtonSize size;

  /// 是否撑满可用宽度（与既有页面按钮外观保持一致）。
  final bool expand;

  /// 是否处于提交中（展示等尺寸加载圈，同时禁用点击）。
  final bool loading;
const AppButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.kind = AppButtonKind.primary,
    this.size = AppButtonSize.large,
    this.expand = true,
    this.loading = false,
  });

  double get _height => switch (size) {
    AppButtonSize.large => 48,
    AppButtonSize.medium => 40,
    AppButtonSize.small => 32,
  };

  double get _fontSize => switch (size) {
    AppButtonSize.large => AppFont.title,
    AppButtonSize.medium => AppFont.bodyLg,
    AppButtonSize.small => AppFont.body,
  };

  double get _iconSize => switch (size) {
    AppButtonSize.large => 18,
    AppButtonSize.medium => 17,
    AppButtonSize.small => 15,
  };

  EdgeInsets get _padding =>
      EdgeInsets.symmetric(horizontal: size == AppButtonSize.small ? 10 : 16);

  ButtonStyle _style(Color bg, Color fg) => ButtonStyle(
    backgroundColor: WidgetStatePropertyAll<Color>(bg),
    foregroundColor: WidgetStatePropertyAll<Color>(fg),
    overlayColor: WidgetStatePropertyAll<Color>(fg.withValues(alpha: 0.08)),
    minimumSize: WidgetStatePropertyAll<Size>(Size(0, _height)),
    padding: WidgetStatePropertyAll<EdgeInsets>(_padding),
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
    ),
    textStyle: WidgetStatePropertyAll<TextStyle>(
      TextStyle(fontSize: _fontSize, fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (kind) {
      AppButtonKind.primary => (AppTheme.primary, Colors.white),
      AppButtonKind.danger => (AppTheme.danger, Colors.white),
      AppButtonKind.tonal => (
        AppTheme.primary.withValues(alpha: 0.10),
        AppTheme.primary,
      ),
      AppButtonKind.secondary => (Colors.transparent, AppTheme.primary),
      AppButtonKind.dangerOutline => (Colors.transparent, AppTheme.danger),
      AppButtonKind.ghost => (Colors.transparent, AppTheme.primary),
    };

    final Widget content = loading
        ? SizedBox(
            width: _iconSize + 2,
            height: _iconSize + 2,
            child: const CircularProgressIndicator(strokeWidth: 2),
          )
        : (icon == null
              ? Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: _iconSize),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ));

    final VoidCallback? cb = (onPressed == null || loading) ? null : onPressed;

    final Widget button = switch (kind) {
      AppButtonKind.secondary => OutlinedButton(
        onPressed: cb,
        style: _style(bg, fg).merge(
          OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFFD7DCE8)),
          ),
        ),
        child: content,
      ),
      AppButtonKind.dangerOutline => OutlinedButton(
        onPressed: cb,
        style: _style(bg, fg).merge(
          OutlinedButton.styleFrom(side: const BorderSide(color: AppTheme.danger)),
        ),
        child: content,
      ),
      AppButtonKind.ghost => TextButton(
        onPressed: cb,
        style: _style(bg, fg),
        child: content,
      ),
      _ => FilledButton(onPressed: cb, style: _style(bg, fg), child: content),
    };

    if (!expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}
