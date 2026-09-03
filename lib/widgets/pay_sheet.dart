import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../theme.dart';

/// 支付确认弹层（过渡期个人收款码方案）。
/// 展示本单随机金额与收款方式，点一下收款方式直接拉起对应支付；
/// 付款完成后点「我已完成付款」→「是的」提交待确认，后台核实后自动开通。
///
/// 返回 true 表示已成功提交「待确认」。
Future<bool> showPaySheet(
  BuildContext context, {
  required Map<String, dynamic> order,
  required String planName,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _PaySheet(order: order, planName: planName),
  ).then((v) => v ?? false);
}

class _PaySheet extends StatefulWidget {
  final Map<String, dynamic> order;
  final String planName;
  const _PaySheet({required this.order, required this.planName});

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  final bool _submitting = false;
  String? _notice; // 提交后的状态提示

  Map<String, dynamic> get _qrcode =>
      (widget.order['qrcode'] as Map<String, dynamic>?) ?? const {};

  /// 拉起指定收款方式（url_launcher，点一下直接打开对应支付）。
  Future<void> _launch(String key) async {
    final link = (_qrcode[key] ?? '').toString().trim();
    if (link.isEmpty) return;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到可用的支付方式')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开支付应用，请检查是否已安装')),
        );
      }
    }
  }

  /// 提交「是的」：订单标记为待确认，不直接开通。
  Future<void> _submit() async {
    if (_submitting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('付款完成了吗？'),
        content: Text(
            '请确认已向收款码支付 ${widget.order['amount'].toStringAsFixed(2)} 元。\n'
            '确认后我们会尽快核实到账。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('还没')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('是的'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _notice = '订单待确认中');
    try {
      final res = await ApiClient.instance
          .confirmOrder((widget.order['orderId'] as num).toInt());
      if (!mounted) return;
      final status = (res['status'] ?? '').toString();
      if (status == 'paid') {
        setState(() => _notice = '已开通专业版');
      } else {
        setState(() => _notice = '等待收款确认');
      }
      // 刷新云端订阅状态
      try {
        await AppState.instance.refreshCloud();
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_notice ?? '订单待确认')),
      );
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _notice = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final amount = (widget.order['amount'] as num?)?.toDouble() ?? 0;
    final hasWx = (_qrcode['wechat'] ?? '').toString().trim().isNotEmpty;
    final hasAli = (_qrcode['alipay'] ?? '').toString().trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(widget.planName,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '¥${amount.toStringAsFixed(2)}',
                style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary),
              ),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text(
                '本单应付金额（随机），请按此金额付款',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
            const SizedBox(height: 20),
            Text('选择收款方式：',
                style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _PayChannelButton(
                    label: '微信收款码',
                    icon: Icons.wechat,
                    color: const Color(0xFF07C160),
                    enabled: hasWx,
                    onTap: () => _launch('wechat'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PayChannelButton(
                    label: '支付宝收款码',
                    icon: Icons.account_balance_wallet_outlined,
                    color: const Color(0xFF1677FF),
                    enabled: hasAli,
                    onTap: () => _launch('alipay'),
                  ),
                ),
              ],
            ),
            if (!hasWx && !hasAli) ...[
              const SizedBox(height: 8),
              const Text(
                '收款方式暂未配置，请联系商家获取收款码后付款。',
                style: TextStyle(fontSize: 12, color: AppTheme.warn),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: const Text('我已完成付款'),
            ),
            const SizedBox(height: 8),
            if (_notice != null)
              Center(
                child: Text(_notice!,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textSub)),
              ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不付款'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayChannelButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;
  const _PayChannelButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 84,
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.08) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: enabled ? color.withValues(alpha: 0.35) : Colors.grey.shade300,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: enabled ? color : Colors.grey, size: 26),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  color: enabled ? AppTheme.textMain : Colors.grey,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      ),
    );
  }
}
