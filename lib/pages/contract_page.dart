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

/// 合同/协议管理页（v1.11.0，替代 v1.10.0 的发票管理）：
/// 记录签约对象 / 金额 / 签订日期 / 状态（草稿/已签/完成），支持查看与导出。
class ContractPage extends StatefulWidget {
  const ContractPage({super.key});

  @override
  State<ContractPage> createState() => _ContractPageState();
}

class _ContractPageState extends State<ContractPage> {
  List<Contract> _contracts = [];
  bool _loading = true;
  final _fmt = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppDb.instance.getContracts();
    if (!mounted) return;
    setState(() {
      _contracts = list;
      _loading = false;
    });
  }

  // 新增 / 编辑合同
  Future<void> _editContract({Contract? c}) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _ContractEditDialog(contract: c),
    );
    if (result == null || !mounted) return;
    final db = AppDb.instance;
    if (c == null) {
      await db.insertContract(Contract(
        target: result.target,
        amount: result.amount,
        status: result.status,
        signedAt: result.date.millisecondsSinceEpoch,
        contractNo: result.contractNo,
        note: result.note,
      ));
    } else {
      await db.updateContract(c.copyWith(
        target: result.target,
        amount: result.amount,
        status: result.status,
        signedAt: result.date.millisecondsSinceEpoch,
        contractNo: result.contractNo,
        note: result.note,
      ));
    }
    await _load();
  }

  Future<void> _deleteContract(Contract c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除合同记录'),
        content: Text('确定删除「${c.target}」的合同记录吗？'),
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
    await AppDb.instance.deleteContract(c.id!);
    await _load();
  }

  // 状态流转：草稿 -> 已签 -> 完成 -> 草稿
  Future<void> _cycleStatus(Contract c) async {
    final next = switch (c.status) {
      ContractStatus.draft => ContractStatus.signed,
      ContractStatus.signed => ContractStatus.done,
      ContractStatus.done => ContractStatus.draft,
    };
    await AppDb.instance.updateContract(c.copyWith(status: next));
    await _load();
  }

  // 导出 CSV
  Future<void> _export() async {
    if (_contracts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有合同记录，暂无可导出')),
      );
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory(p.join(dir.path, 'exports'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(outDir.path, 'contracts-$stamp.csv'));

    final b = StringBuffer('签约对象,金额(元),签订日期,合同编号,状态,备注\n');
    for (final c in _contracts) {
      final date = DateFormat('yyyy-MM-dd')
          .format(DateTime.fromMillisecondsSinceEpoch(c.signedAt));
      b.writeln('${c.target},${_fmt.format(c.amount / 100)},$date,${c.contractNo},${c.status.label},${c.note.replaceAll(',', '，')}');
    }
    // 带 UTF-8 BOM，保证 Excel 打开中文不乱码
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(b.toString())];
    file.writeAsBytesSync(bytes);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      text: '接单管家 合同记录导出（共 ${_contracts.length} 条）',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('合同管理'),
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
        onPressed: () => _editContract(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contracts.isEmpty
              ? const Center(
                  child: Text('还没有合同记录，点右下角添加',
                      style: TextStyle(color: AppTheme.textSub)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 88),
                  itemCount: _contracts.length,
                  itemBuilder: (ctx, i) {
                    final c = _contracts[i];
                    return Card(
                      child: ListTile(
                        onTap: () => _editContract(c: c),
                        leading: Icon(
                          _statusIcon(c.status),
                          color: _statusColor(c.status),
                        ),
                        title: Text(
                          c.target,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '¥${_fmt.format(c.amount / 100)} · ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(c.signedAt))}'
                          '${c.contractNo.isEmpty ? '' : ' · 编号 ${c.contractNo}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _StatusChip(status: c.status),
                            IconButton(
                              tooltip: '流转状态',
                              icon: const Icon(Icons.swap_horiz,
                                  size: 20, color: AppTheme.primary),
                              onPressed: () => _cycleStatus(c),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline,
                                  size: 20, color: AppTheme.danger),
                              onPressed: () => _deleteContract(c),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  IconData _statusIcon(ContractStatus s) => switch (s) {
        ContractStatus.draft => Icons.edit_note_outlined,
        ContractStatus.signed => Icons.check_circle_outline,
        ContractStatus.done => Icons.task_alt_outlined,
      };

  Color _statusColor(ContractStatus s) => switch (s) {
        ContractStatus.draft => AppTheme.warn,
        ContractStatus.signed => AppTheme.accent,
        ContractStatus.done => AppTheme.primary,
      };
}

class _EditResult {
  final String target;
  final int amount;
  final DateTime date;
  final ContractStatus status;
  final String contractNo;
  final String note;
  const _EditResult({
    required this.target,
    required this.amount,
    required this.date,
    required this.status,
    required this.contractNo,
    required this.note,
  });
}

class _ContractEditDialog extends StatefulWidget {
  final Contract? contract;
  const _ContractEditDialog({this.contract});

  @override
  State<_ContractEditDialog> createState() => _ContractEditDialogState();
}

class _ContractEditDialogState extends State<_ContractEditDialog> {
  late final TextEditingController _targetCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;
  late ContractStatus _status;

  @override
  void initState() {
    super.initState();
    final c = widget.contract;
    _targetCtrl = TextEditingController(text: c?.target ?? '');
    _amountCtrl = TextEditingController(
        text: c == null ? '' : Money.yuan(c.amount));
    _noCtrl = TextEditingController(text: c?.contractNo ?? '');
    _noteCtrl = TextEditingController(text: c?.note ?? '');
    _date = c == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(c.signedAt);
    _status = c?.status ?? ContractStatus.draft;
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
    final isNew = widget.contract == null;
    return AlertDialog(
      title: Text(isNew ? '新增合同' : '编辑合同'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _targetCtrl,
              decoration: const InputDecoration(
                  labelText: '签约对象（客户 / 公司名）', isDense: true),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: '合同金额（元）', isDense: true),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('签订日期', style: TextStyle(fontSize: 14)),
              trailing: Text(
                  DateFormat('yyyy-MM-dd').format(_date),
                  style: const TextStyle(color: AppTheme.primary)),
              onTap: _pickDate,
            ),
            DropdownButtonFormField<ContractStatus>(
              initialValue: _status,
              decoration:
                  const InputDecoration(labelText: '状态', isDense: true),
              items: ContractStatus.values
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
                  labelText: '合同编号（可选）', isDense: true),
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
                const SnackBar(content: Text('请填写签约对象和有效金额')),
              );
              return;
            }
            Navigator.pop(context, _EditResult(
              target: target,
              amount: amount,
              date: _date,
              status: _status,
              contractNo: _noCtrl.text.trim(),
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
  final ContractStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ContractStatus.draft => AppTheme.warn,
      ContractStatus.signed => AppTheme.accent,
      ContractStatus.done => AppTheme.primary,
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
