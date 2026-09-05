import 'package:flutter/material.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../state/ticker.dart';
import '../utils/money_input.dart';

/// 弹出「登记收款」对话框（项目详情页与项目列表页共用）。
///
/// 智能默认：
/// - 已收总额为零、尚未收过款 -> 默认类型「定金」，金额留空
/// - 已收过定金、仍有剩余    -> 默认类型「尾款」，金额预填剩余待收
/// - 已收满 / 未约定总额      -> 默认类型「全额」，金额预填剩余待收
///
/// 返回 true 表示成功新增了一笔收款。
Future<bool> showPaymentDialog(
  BuildContext context, {
  required int projectId,
  required int amountTotal, // 分
  required int paidTotal, // 分
  int? quoteId, // 预选关联报价单 id（第17批：基于 quote_id 精确关联，可空）
}) async {
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final customTypeCtrl = TextEditingController();
  final remaining = amountTotal - paidTotal < 0 ? 0 : amountTotal - paidTotal;

  // 第17批关联报价：载入该项目下非模板报价单供精确关联；项目无报价时不显示该选项。
  final quotes = (await AppDb.instance.getQuotesByProject(projectId))
      .where((q) => !q.isTemplate)
      .toList();
  var selQuote =
      quoteId != null && quotes.any((q) => q.id == quoteId) ? quoteId : null;
  // 跨 async 间隙后再使用 context，先做 mounted 防护（第17批关联报价载入后）
  if (!context.mounted) return false;

  // 根据收款阶段挑选默认类型
  late PayType defaultType;
  String amountHint = '';
  if (amountTotal <= 0) {
    // 未约定总额，只能收全额
    defaultType = PayType.full;
  } else if (paidTotal <= 0) {
    defaultType = PayType.deposit;
    amountHint = paidTotal <= 0 && remaining > 0
        ? '可收定金，剩余待收 ¥${Money.yuan(remaining)}'
        : '';
  } else if (remaining > 0) {
    defaultType = PayType.balance;
    amountHint = '剩余待收 ¥${Money.yuan(remaining)}';
  } else {
    defaultType = PayType.full;
  }

  // 有剩余时预填剩余金额，一键保存
  if (remaining > 0 && amountTotal > 0) {
    amountCtrl.text = Money.yuan(remaining);
  }

  var type = defaultType;
  var customTypeError = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: const Text('登记收款'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: moneyInputFormatters,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '金额（元） *',
                hintText: amountHint,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PayType>(
              initialValue: type,
              decoration: const InputDecoration(labelText: '类型'),
              items: PayType.values
                  .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                  .toList(),
              onChanged: (v) => setDlg(() => type = v!),
            ),
            if (type == PayType.custom) ...[
              const SizedBox(height: 12),
              TextField(
                controller: customTypeCtrl,
                decoration: InputDecoration(
                  labelText: '自定义类型名称 *',
                  hintText: '如：首期款 / 二期款 / 质保金',
                  errorText: customTypeError ? '请输入自定义类型名称' : null,
                ),
                onChanged: (_) => setDlg(() => customTypeError = false),
              ),
            ],
            const SizedBox(height: 12),
            if (quotes.isNotEmpty) ...[
              DropdownButtonFormField<int?>(
                initialValue: selQuote,
                decoration: const InputDecoration(labelText: '关联报价'),
                items: [
                  const DropdownMenuItem<int?>(
                      value: null, child: Text('不关联报价')),
                  for (final q in quotes)
                    DropdownMenuItem<int?>(
                      value: q.id,
                      child: Text('${q.title} · ¥${Money.yuan(q.total)}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setDlg(() => selQuote = v),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(labelText: '备注', hintText: '如：首期款到账'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(amountCtrl.text.trim());
              if (v == null || v <= 0) {
                Navigator.pop(ctx, false);
                return;
              }
              if (type == PayType.custom &&
                  customTypeCtrl.text.trim().isEmpty) {
                setDlg(() => customTypeError = true);
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );

  if (ok == true) {
    await AppDb.instance.insertPayment(Payment(
      projectId: projectId,
      amount: Money.parseYuanToFen(amountCtrl.text.trim()),
      type: type,
      typeLabel: type == PayType.custom ? customTypeCtrl.text.trim() : '',
      paidAt: DateTime.now().millisecondsSinceEpoch,
      note: noteCtrl.text.trim(),
      quoteId: selQuote,
    ));
    Ticker.ping();
    return true;
  }
  return false;
}
