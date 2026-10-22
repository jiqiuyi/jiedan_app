import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

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
        ? L10n.instance.t('i18n_162', args: {'v0': Money.yuan(remaining)})
        : '';
  } else if (remaining > 0) {
    defaultType = PayType.balance;
    amountHint = L10n.instance.t('i18n_150', args: {'v0': Money.yuan(remaining)});
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
        title: Text(L10n.instance.t('project_record_payment')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: moneyInputFormatters,
              autofocus: true,
              decoration: InputDecoration(
                labelText: L10n.instance.t('i18n_622'),
                hintText: amountHint,
              ),
            ),
            SizedBox(height: 12),
            DropdownButtonFormField<PayType>(
              initialValue: type,
              decoration: InputDecoration(labelText: L10n.instance.t('common_type')),
              items: PayType.values
                  .map((e) => DropdownMenuItem(value: e, child: Text(e.label)))
                  .toList(),
              onChanged: (v) => setDlg(() => type = v!),
            ),
            if (type == PayType.custom) ...[
              SizedBox(height: 12),
              TextField(
                controller: customTypeCtrl,
                decoration: InputDecoration(
                  labelText: L10n.instance.t('i18n_545'),
                  hintText: L10n.instance.t('payment_dialog_type_example'),
                  errorText: customTypeError ? L10n.instance.t('payment_dialog_custom_type') : null,
                ),
                onChanged: (_) => setDlg(() => customTypeError = false),
              ),
            ],
            SizedBox(height: 12),
            if (quotes.isNotEmpty) ...[
              DropdownButtonFormField<int?>(
                initialValue: selQuote,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_133')),
                items: [
                  DropdownMenuItem<int?>(
                      value: null, child: Text(L10n.instance.t('payment_dialog_no_quote'))),
                  for (final q in quotes)
                    DropdownMenuItem<int?>(
                      value: q.id,
                      child: Text('${q.title} · ¥${Money.yuan(q.total)}',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setDlg(() => selQuote = v),
              ),
              SizedBox(height: 12),
            ],
            TextField(
              controller: noteCtrl,
              decoration: InputDecoration(labelText: L10n.instance.t('common_note'), hintText: L10n.instance.t('payment_dialog_remark_example')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
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
            child: Text(L10n.instance.t('common_save')),
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
