import 'dart:io';

import 'package:flutter/material.dart';

import '../database.dart';
import '../theme.dart';
import '../pages/payment_code_settings_page.dart';

/// 出示收款码底部弹层（方案A：个人收款码 + 手动确认到账）。
/// 展示已配置的微信 / 支付宝收款码，供客户扫码付款。
Future<void> showPaymentCodeSheet(BuildContext context) async {
  final db = AppDb.instance;
  final wxPath = await db.getWxQrPath();
  final aliPath = await db.getAliQrPath();
  final hasWx = wxPath != null && wxPath.isNotEmpty;
  final hasAli = aliPath != null && aliPath.isNotEmpty;

  if (!context.mounted) return;

  // 一个都没配置：引导去设置
  if (!hasWx && !hasAli) {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('尚未配置收款码'),
        content: const Text('先在「我的 → 收款设置」里选择微信 / 支付宝收款码截图，收款时才能出示给客户扫码。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('暂不')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const PaymentCodeSettingsPage()),
      );
    }
    return;
  }

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _Sheet(
      wxPath: hasWx ? wxPath : null,
      aliPath: hasAli ? aliPath : null,
    ),
  );
}

class _Sheet extends StatefulWidget {
  final String? wxPath;
  final String? aliPath;
  const _Sheet({required this.wxPath, required this.aliPath});

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  int _tab = 0; // 0=微信 1=支付宝

  @override
  Widget build(BuildContext context) {
    final wx = widget.wxPath != null;
    final ali = widget.aliPath != null;
    if (_tab == 1 && !ali) _tab = 0;
    final current = _tab == 0 ? widget.wxPath : widget.aliPath;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('出示收款码',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('请客户扫码付款',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
            const SizedBox(height: 12),
            if (wx && ali)
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('微信'), icon: Icon(Icons.wechat)),
                  ButtonSegment(value: 1, label: Text('支付宝'), icon: Icon(Icons.account_balance_wallet_outlined)),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            const SizedBox(height: 12),
            if (current != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(current),
                  width: 280,
                  height: 280,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('收款码图片加载失败，请到「收款设置」重新配置'),
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('该收款码尚未配置',
                    style: TextStyle(color: AppTheme.textSub)),
              ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline, size: 16, color: AppTheme.accent),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '客户付款到账后，请返回点击「登记收款」完成入账。',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
