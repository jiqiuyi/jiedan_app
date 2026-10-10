import 'package:flutter/material.dart';

import '../theme.dart';

/// 统一底部弹层：白底、顶部圆角 20，全 App 一致。
///
/// 用于替代各页手写 `showModalBottomSheet(... shape: ...)` 的重复配置。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useRootNavigator: useRootNavigator,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: builder,
  );
}

/// 弹层标题区：标题 16 w700 + 可选副标题 13 次要色。
class AppSheetHeader extends StatelessWidget {
  /// 标题文案。
  final String title;

  /// 可选副标题。
  final String? subtitle;

  const AppSheetHeader({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: AppFont.title,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(
              fontSize: AppFont.body,
              color: AppTheme.textSub,
            ),
          ),
        ],
      ],
    );
  }
}
