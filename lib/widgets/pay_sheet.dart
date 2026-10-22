import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../theme.dart';
import '../widgets/app_ui.dart';

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
  return showAppSheet<bool>(
    context,
    isScrollControlled: true,
    builder: (ctx) => _PaySheet(order: order, planName: planName),
  ).then((v) => v ?? false);
}

class _PaySheet extends StatefulWidget {
  final Map<String, dynamic> order;
  final String planName;
const   _PaySheet({required this.order, required this.planName});

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  final bool _submitting = false;
  String? _notice; // 提交后的状态提示

  Map<String, dynamic> get _qrcode =>
      (widget.order['qrcode'] as Map<String, dynamic>?) ?? {};

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
          SnackBar(content: Text(L10n.instance.t('pay_sheet_no_method'))),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('pay_sheet_cannot_open'))),
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
        title: Text(L10n.instance.t('pay_sheet_done_ask')),
        content: Text(
            L10n.instance.t('pay_sheet_confirm_amount', args: {'v0': widget.order['amount'].toStringAsFixed(2)}) +
            L10n.instance.t('i18n_509')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_not_yet'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_yes')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _notice = L10n.instance.t('i18n_559'));
    try {
      final res = await ApiClient.instance
          .confirmOrder((widget.order['orderId'] as num).toInt());
      if (!mounted) return;
      final status = (res['status'] ?? '').toString();
      if (status == 'paid') {
        setState(() => _notice = L10n.instance.t('i18n_269'));
      } else {
        setState(() => _notice = L10n.instance.t('i18n_519'));
      }
      // 刷新云端订阅状态
      try {
        await AppState.instance.refreshCloud();
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_notice ?? L10n.instance.t('pay_sheet_order_pending'))),
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
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            SizedBox(height: 8),
            Center(
              child: Text(
                '¥${amount.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary),
              ),
            ),
            SizedBox(height: 4),
            Center(
              child: Text(
                L10n.instance.t('i18n_450'),
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
            SizedBox(height: 20),
            Text(L10n.instance.t('pay_sheet_choose'),
                style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _PayChannelButton(
                    label: L10n.instance.t('payment_code_wechat'),
                    icon: Icons.wechat,
                    color: const Color(0xFF07C160),
                    enabled: hasWx,
                    onTap: () => _launch('wechat'),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: _PayChannelButton(
                    label: L10n.instance.t('payment_code_alipay'),
                    icon: Icons.account_balance_wallet_outlined,
                    color: const Color(0xFF1677FF),
                    enabled: hasAli,
                    onTap: () => _launch('alipay'),
                  ),
                ),
              ],
            ),
            if (!hasWx && !hasAli) ...[
              SizedBox(height: 8),
              Text(
                L10n.instance.t('i18n_384'),
                style: TextStyle(fontSize: 12, color: AppTheme.warn),
              ),
            ],
            SizedBox(height: 20),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Text(L10n.instance.t('pay_sheet_done')),
            ),
            SizedBox(height: 8),
            if (_notice != null)
              Center(
                child: Text(_notice!,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textSub)),
              ),
            SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(L10n.instance.t('pay_sheet_not_now')),
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
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        height: 84,
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.08) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(AppRadius.md),
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
