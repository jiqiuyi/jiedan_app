import 'package:flutter/material.dart';

import '../theme.dart';

/// 统一错误态：图标 + 主文案 + 可选补充说明 + 重试按钮。
/// 所有列表 / 看板页数据加载失败时必须落到本组件，绝不允许无限转圈。
class AppError extends StatelessWidget {
  /// 顶部图标。
  final IconData icon;

  /// 主文案。
  final String title;

  /// 可选补充说明。
  final String? hint;

  /// 重试回调（为空则不显示按钮）。
  final VoidCallback? onRetry;

  /// 文字与图标颜色。
  final Color color;

  const AppError({
    super.key,
    this.icon = Icons.error_outline,
    required this.title,
    this.hint,
    this.onRetry,
    this.color = AppTheme.danger,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppFont.bodyLg, color: color),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppFont.tag,
                  color: AppTheme.textSub.withValues(alpha: 0.8),
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 统一加载态：全 App 一致的进度圈尺寸与线宽。
class AppLoading extends StatelessWidget {
  /// 进度圈直径（默认 28）。
  final double size;

  /// 线宽（默认 2.5）。
  final double strokeWidth;

  const AppLoading({super.key, this.size = 28, this.strokeWidth = 2.5});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: strokeWidth),
      ),
    );
  }
}

/// 统一空状态：图标 + 主文案 + 可选补充说明。
class AppEmpty extends StatelessWidget {
  /// 顶部图标。
  final IconData icon;

  /// 主文案。
  final String title;

  /// 可选补充说明。
  final String? hint;

  /// 文字与图标颜色。
  final Color color;

  const AppEmpty({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.title,
    this.hint,
    this.color = AppTheme.textSub,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: color.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppFont.bodyLg, color: color),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppFont.tag,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
