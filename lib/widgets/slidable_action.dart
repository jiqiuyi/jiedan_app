import 'package:flutter/material.dart';

/// 左滑操作按钮内容：图标 + 文字（竖排），配合 flutter_slidable 使用。
class SlidableActionContent extends StatelessWidget {
  final IconData icon;
  final String label;
  const SlidableActionContent({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 22),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
