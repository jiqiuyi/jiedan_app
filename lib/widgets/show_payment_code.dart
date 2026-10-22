import 'dart:io';
import '../l10n/l10n.dart';

import 'package:flutter/material.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../state/ticker.dart';
import '../theme.dart';
import '../services/pay_service.dart';
import '../pages/payment_code_settings_page.dart';
import '../utils/money_input.dart';
import '../widgets/app_ui.dart';

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
        title: Text(L10n.instance.t('show_payment_not_configured')),
        content: Text(L10n.instance.t('show_payment_configure_hint')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_not_now'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('payment_code_go_settings')),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PaymentCodeSettingsPage()),
      );
    }
    return;
  }

  await showAppSheet(
    context,
    isScrollControlled: true,
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
    final double qrSize = (MediaQuery.sizeOf(context).width - 32).clamp(200.0, 280.0);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(L10n.instance.t('payment_show_code'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            SizedBox(height: 4),
            Text(L10n.instance.t('show_payment_scan_pay'),
                style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
            SizedBox(height: 12),
            if (wx && ali)
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 0, label: Text(L10n.instance.t('common_wechat')), icon: Icon(Icons.wechat)),
                  ButtonSegment(value: 1, label: Text(L10n.instance.t('common_alipay')), icon: Icon(Icons.account_balance_wallet_outlined)),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
            SizedBox(height: 12),
            if (current != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.file(
                  File(current),
                  width: qrSize,
                  height: qrSize,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(L10n.instance.t('show_payment_image_failed')),
                  ),
                ),
              )
            else
              Padding(
                padding: EdgeInsets.all(24),
                child: Text(L10n.instance.t('show_payment_not_configured2'),
                    style: TextStyle(color: AppTheme.textSub)),
              ),
            SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline, size: 16, color: AppTheme.accent),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      L10n.instance.t('i18n_226'),
                      style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(L10n.instance.t('common_close')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 项目收款流程（看板 / 项目详情"收款"入口共用）：
/// 选择渠道（微信 / 支付宝）→ 展示收款码大图供客户扫码 →
/// 手动确认到账（输入实收金额 + 收款类型）→ 生成一条收款记录，自动累加到项目已收金额并刷新看板。
///
/// 返回 true 表示成功入账一笔。
Future<bool> showProjectCollectSheet(
  BuildContext context, {
  required int projectId,
  required String projectTitle,
  required int amountTotal, // 分
  required int paidTotal, // 分
}) async {
  final db = AppDb.instance;
  final wxPath = await db.getWxQrPath();
  final aliPath = await db.getAliQrPath();
  final hasWx = wxPath != null && wxPath.isNotEmpty;
  final hasAli = aliPath != null && aliPath.isNotEmpty;

  if (!context.mounted) return false;

  // 一个都没配置：引导去设置
  if (!hasWx && !hasAli) {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('show_payment_not_configured')),
        content: Text(L10n.instance.t('show_payment_configure_hint2')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_not_now'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('payment_code_go_settings')),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PaymentCodeSettingsPage()),
      );
    }
    return false;
  }

  final done = await showAppSheet<bool>(
    context,
    isScrollControlled: true,
    builder: (ctx) => _ProjectCollectSheet(
      projectId: projectId,
      projectTitle: projectTitle,
      amountTotal: amountTotal,
      paidTotal: paidTotal,
      wxPath: hasWx ? wxPath : null,
      aliPath: hasAli ? aliPath : null,
    ),
  );
  return done ?? false;
}

class _ProjectCollectSheet extends StatefulWidget {
  final int projectId;
  final String projectTitle;
  final int amountTotal; // 分
  final int paidTotal; // 分
  final String? wxPath;
  final String? aliPath;
const _ProjectCollectSheet({
    required this.projectId,
    required this.projectTitle,
    required this.amountTotal,
    required this.paidTotal,
    required this.wxPath,
    required this.aliPath,
  });

  @override
  State<_ProjectCollectSheet> createState() => _ProjectCollectSheetState();
}

class _ProjectCollectSheetState extends State<_ProjectCollectSheet> {
  int _tab = 0; // 0=微信 1=支付宝
  PayType _type = PayType.full;
  final _amountCtrl = TextEditingController();
  final _customTypeCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final remaining = widget.amountTotal - widget.paidTotal < 0
        ? 0
        : widget.amountTotal - widget.paidTotal;
    if (widget.amountTotal > 0 && remaining > 0) {
      _amountCtrl.text = Money.yuan(remaining);
    }
    // 默认类型：未收过->定金；有剩余->尾款；否则全额
    if (widget.paidTotal <= 0 && widget.amountTotal > 0) {
      _type = PayType.deposit;
    } else if (remaining > 0) {
      _type = PayType.balance;
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _customTypeCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_saving) return; // 防重复提交
    final v = double.tryParse(_amountCtrl.text.trim());
    if (v == null || v <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('show_payment_invalid_amount'))),
      );
      return;
    }
    if (_type == PayType.custom && _customTypeCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('show_payment_custom_type'))),
      );
      return;
    }
    setState(() => _saving = true);
    // 真实支付接入前：向通道查询订单状态（MVP 手动模式返回无需查询；
    // 接入真实商户后此处会返回平台查单结果，据此判断是否到账）。
    await Channels.pay.query(PaymentRequest(
      orderId: 'PR${DateTime.now().millisecondsSinceEpoch}',
      amount: double.parse(v.toStringAsFixed(2)),
      title: widget.projectTitle,
    ));
    final amountFen = Money.parseYuanToFen(v.toStringAsFixed(2));
    await AppDb.instance.insertPayment(Payment(
      projectId: widget.projectId,
      amount: amountFen,
      type: _type,
      typeLabel: _type == PayType.custom ? _customTypeCtrl.text.trim() : '',
      paidAt: DateTime.now().millisecondsSinceEpoch,
      note: _noteCtrl.text.trim(),
    ));
    Ticker.ping(); // 刷新看板 / 项目详情
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final wx = widget.wxPath != null;
    final ali = widget.aliPath != null;
    if (_tab == 1 && !ali) _tab = 0;
    final current = _tab == 0 ? widget.wxPath : widget.aliPath;
    final double qrSize = (MediaQuery.sizeOf(context).width - 32).clamp(180.0, 240.0);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(L10n.instance.t('payment_project_title'),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              SizedBox(height: 4),
              Center(
                child: Text(widget.projectTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              ),
              SizedBox(height: 12),
              if (wx && ali)
                Center(
                  child: SegmentedButton<int>(
                    segments: [
                      ButtonSegment(value: 0, label: Text(L10n.instance.t('common_wechat')), icon: Icon(Icons.wechat)),
                      ButtonSegment(value: 1, label: Text(L10n.instance.t('common_alipay')), icon: Icon(Icons.account_balance_wallet_outlined)),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                ),
              SizedBox(height: 12),
              Center(
                child: current != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: Image.file(
                          File(current),
                          width: qrSize,
                          height: qrSize,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(L10n.instance.t('show_payment_image_failed')),
                          ),
                        ),
                      )
                    : Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(L10n.instance.t('show_payment_not_configured2'),
                            style: TextStyle(color: AppTheme.textSub)),
                      ),
              ),
              SizedBox(height: 12),
              Text(L10n.instance.t('show_payment_manual_confirm'),
                  style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              SizedBox(height: 8),
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: moneyInputFormatters,
                decoration: InputDecoration(
                  labelText: L10n.instance.t('i18n_224'),
                  hintText: widget.amountTotal > 0
                      ? L10n.instance.t('i18n_531', args: {'v0': Money.yuan(widget.amountTotal), 'v1': Money.yuan(widget.paidTotal)})
                      : L10n.instance.t('i18n_442'),
                  prefixText: '¥ ',
                ),
              ),
              SizedBox(height: 12),
              DropdownButtonFormField<PayType>(
                initialValue: _type,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_386')),
                items: PayType.values
                    .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v!),
              ),
              if (_type == PayType.custom) ...[
                SizedBox(height: 12),
                TextField(
                  controller: _customTypeCtrl,
                  decoration: InputDecoration(
                    labelText: L10n.instance.t('i18n_545'),
                    hintText: L10n.instance.t('payment_dialog_type_example'),
                  ),
                ),
              ],
              SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                decoration: InputDecoration(labelText: L10n.instance.t('common_note'), hintText: L10n.instance.t('show_payment_example')),
              ),
              SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _confirm,
                  child: _saving
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(L10n.instance.t('show_payment_confirm_record')),
                ),
              ),
              SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(L10n.instance.t('common_cancel')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
