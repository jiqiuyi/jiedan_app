import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../state/ticker.dart';
import '../theme.dart';
import '../services/pay_service.dart';
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
        title: const Text('尚未配置收款码'),
        content: const Text('请先到「我的 → 收款设置」上传自己的微信 / 支付宝收款码，收款时才能出示给客户扫码。'),
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
    return false;
  }

  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
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
        const SnackBar(content: Text('请输入有效的实收金额')),
      );
      return;
    }
    if (_type == PayType.custom && _customTypeCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入自定义收款类型名称')),
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
                child: Text('项目收款',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(widget.projectTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSub)),
              ),
              const SizedBox(height: 12),
              if (wx && ali)
                Center(
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('微信'), icon: Icon(Icons.wechat)),
                      ButtonSegment(value: 1, label: Text('支付宝'), icon: Icon(Icons.account_balance_wallet_outlined)),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                ),
              const SizedBox(height: 12),
              Center(
                child: current != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(current),
                          width: 240,
                          height: 240,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('收款码图片加载失败，请到「收款设置」重新配置'),
                          ),
                        ),
                      )
                    : const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('该收款码尚未配置',
                            style: TextStyle(color: AppTheme.textSub)),
                      ),
              ),
              const SizedBox(height: 12),
              const Text('客户扫码付款后，手动确认到账：',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              const SizedBox(height: 8),
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: InputDecoration(
                  labelText: '实收金额（元） *',
                  hintText: widget.amountTotal > 0
                      ? '约定总额 ¥${Money.yuan(widget.amountTotal)}，已收 ¥${Money.yuan(widget.paidTotal)}'
                      : '未约定总额',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PayType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: '收款类型'),
                items: PayType.values
                    .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v!),
              ),
              if (_type == PayType.custom) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _customTypeCtrl,
                  decoration: const InputDecoration(
                    labelText: '自定义类型名称 *',
                    hintText: '如：首期款 / 二期款 / 质保金',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                decoration: const InputDecoration(labelText: '备注', hintText: '如：客户已扫码付款'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _confirm,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('确认到账并登记'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
