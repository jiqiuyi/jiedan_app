import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../database.dart';
import '../models.dart';
import '../theme.dart';
import '../constants.dart';

/// 发票管理页（v1.10.0 新增）：
/// 记录开票对象 / 金额 / 日期 / 状态（待开票/已开票/已作废），支持查看与导出。
class InvoicePage extends StatefulWidget {
  const InvoicePage({super.key});

  @override
  State<InvoicePage> createState() => _InvoicePageState();
}

class _InvoicePageState extends State<InvoicePage> {
  List<Invoice> _invoices = [];
  bool _loading = true;
  final _fmt = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppDb.instance.getInvoices();
    if (!mounted) return;
    setState(() {
      _invoices = list;
      _loading = false;
    });
  }

  // 新增 / 编辑发票
  Future<void> _editInvoice({Invoice? inv}) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _InvoiceEditDialog(invoice: inv),
    );
    if (result == null || !mounted) return;
    final db = AppDb.instance;
    if (inv == null) {
      await db.insertInvoice(Invoice(
        target: result.target,
        amount: result.amount,
        status: result.status,
        issuedAt: result.date.millisecondsSinceEpoch,
        invoiceNo: result.invoiceNo,
        note: result.note,
      ));
    } else {
      await db.updateInvoice(inv.copyWith(
        target: result.target,
        amount: result.amount,
        status: result.status,
        issuedAt: result.date.millisecondsSinceEpoch,
        invoiceNo: result.invoiceNo,
        note: result.note,
      ));
    }
    await _load();
  }

  Future<void> _deleteInvoice(Invoice inv) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除发票记录'),
        content: Text('确定删除「${inv.target}」的发票记录吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.deleteInvoice(inv.id!);
    await _load();
  }

  // 状态流转：待开票 -> 已开票 -> 作废 -> 待开票
  Future<void> _cycleStatus(Invoice inv) async {
    final next = switch (inv.status) {
      InvoiceStatus.draft => InvoiceStatus.issued,
      InvoiceStatus.issued => InvoiceStatus.voided,
      InvoiceStatus.voided => InvoiceStatus.draft,
    };
    await AppDb.instance.updateInvoice(inv.copyWith(status: next));
    await _load();
  }

  // 导出 CSV
  Future<void> _export() async {
    if (_invoices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有发票记录，暂无可导出')),
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'exports'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(outDir.path, 'invoices-$stamp.csv'));

    final b = StringBuffer('开票对象,金额(元),开票日期,发票号码,状态,备注\n');
    for (final inv in _invoices) {
      final date = DateFormat('yyyy-MM-dd')
          .format(DateTime.fromMillisecondsSinceEpoch(inv.issuedAt));
      b.writeln('${inv.target},${_fmt.format(inv.amount / 100)},$date,${inv.invoiceNo},${inv.status.label},${inv.note.replaceAll(',', '，')}');
    }
    // 带 UTF-8 BOM，保证 Excel 打开中文不乱码
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(b.toString())];
    file.writeAsBytesSync(bytes);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      text: '接单管家 发票记录导出（共 ${_invoices.length} 条）',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发票记录'),
        actions: [
          IconButton(
            tooltip: '导出 CSV',
            icon: const Icon(Icons.ios_share),
            onPressed: _export,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: () => _editInvoice(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _invoices.isEmpty
              ? const Center(
                  child: Text('还没有发票记录，点右下角添加',
                      style: TextStyle(color: AppTheme.textSub)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 88),
                  itemCount: _invoices.length,
                  itemBuilder: (ctx, i) {
                    final inv = _invoices[i];
                    return Card(
                      child: ListTile(
                        onTap: () => _editInvoice(inv: inv),
                        leading: Icon(
                          _statusIcon(inv.status),
                          color: _statusColor(inv.status),
                        ),
                        title: Text(
                          inv.target,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '¥${_fmt.format(inv.amount / 100)} · ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(inv.issuedAt))}'
                          '${inv.invoiceNo.isEmpty ? '' : ' · 票号 ${inv.invoiceNo}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _StatusChip(status: inv.status),
                            IconButton(
                              tooltip: '流转状态',
                              icon: const Icon(Icons.swap_horiz,
                                  size: 20, color: AppTheme.primary),
                              onPressed: () => _cycleStatus(inv),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline,
                                  size: 20, color: AppTheme.danger),
                              onPressed: () => _deleteInvoice(inv),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  IconData _statusIcon(InvoiceStatus s) => switch (s) {
        InvoiceStatus.draft => Icons.edit_note_outlined,
        InvoiceStatus.issued => Icons.check_circle_outline,
        InvoiceStatus.voided => Icons.cancel_outlined,
      };

  Color _statusColor(InvoiceStatus s) => switch (s) {
        InvoiceStatus.draft => AppTheme.warn,
        InvoiceStatus.issued => AppTheme.accent,
        InvoiceStatus.voided => AppTheme.textSub,
      };
}

class _EditResult {
  final String target;
  final int amount;
  final DateTime date;
  final InvoiceStatus status;
  final String invoiceNo;
  final String note;
  const _EditResult({
    required this.target,
    required this.amount,
    required this.date,
    required this.status,
    required this.invoiceNo,
    required this.note,
  });
}

class _InvoiceEditDialog extends StatefulWidget {
  final Invoice? invoice;
  const _InvoiceEditDialog({this.invoice});

  @override
  State<_InvoiceEditDialog> createState() => _InvoiceEditDialogState();
}

class _InvoiceEditDialogState extends State<_InvoiceEditDialog> {
  late final TextEditingController _targetCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;
  late InvoiceStatus _status;

  @override
  void initState() {
    super.initState();
    final inv = widget.invoice;
    _targetCtrl = TextEditingController(text: inv?.target ?? '');
    _amountCtrl = TextEditingController(
        text: inv == null ? '' : Money.yuan(inv.amount));
    _noCtrl = TextEditingController(text: inv?.invoiceNo ?? '');
    _noteCtrl = TextEditingController(text: inv?.note ?? '');
    _date = inv == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(inv.issuedAt);
    _status = inv?.status ?? InvoiceStatus.draft;
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    _amountCtrl.dispose();
    _noCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.invoice == null;
    return AlertDialog(
      title: Text(isNew ? '新增发票' : '编辑发票'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _targetCtrl,
              decoration: const InputDecoration(
                  labelText: '开票对象（客户 / 公司名）', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: '开票金额（元）', isDense: true),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开票日期', style: TextStyle(fontSize: 14)),
              trailing: Text(
                  DateFormat('yyyy-MM-dd').format(_date),
                  style: const TextStyle(color: AppTheme.primary)),
              onTap: _pickDate,
            ),
            DropdownButtonFormField<InvoiceStatus>(
              initialValue: _status,
              decoration:
                  const InputDecoration(labelText: '状态', isDense: true),
              items: InvoiceStatus.values
                  .map((s) => DropdownMenuItem(
                      value: s, child: Text(s.label)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _status = v);
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _noCtrl,
              decoration: const InputDecoration(
                  labelText: '发票号码（可选）', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: '备注（可选）', isDense: true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final target = _targetCtrl.text.trim();
            final amount = Money.parseYuanToFen(_amountCtrl.text.trim());
            if (target.isEmpty || amount <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请填写开票对象和有效金额')),
              );
              return;
            }
            Navigator.pop(context, _EditResult(
              target: target,
              amount: amount,
              date: _date,
              status: _status,
              invoiceNo: _noCtrl.text.trim(),
              note: _noteCtrl.text.trim(),
            ));
          },
          child: Text(isNew ? '保存' : '更新'),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final InvoiceStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      InvoiceStatus.draft => AppTheme.warn,
      InvoiceStatus.issued => AppTheme.accent,
      InvoiceStatus.voided => AppTheme.textSub,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(status.label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
