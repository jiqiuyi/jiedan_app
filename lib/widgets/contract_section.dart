import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../state/ticker.dart';
import '../theme.dart';
import '../utils/money_input.dart';
import 'app_ui.dart';
import 'attachment_section.dart';

/// 合同区块（项目详情页内，参照网页版 console.js 合同卡片逻辑）。
///
/// 合同列表（编号/金额/状态/备注摘要）、新增/编辑弹窗、删除；每个合同
/// 卡片下挂附件能力（owner_type='contract'，复用 AttachmentSection）。
class ContractSection extends StatefulWidget {
  final int projectId;
const   ContractSection({super.key, required this.projectId});

  @override
  State<ContractSection> createState() => _ContractSectionState();
}

class _ContractSectionState extends State<ContractSection> {
  List<Contract> _contracts = [];
  bool _loading = true;
  final _fmt = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await AppDb.instance.getContracts();
    if (!mounted) return;
    setState(() {
      _contracts =
          all.where((c) => c.projectId == widget.projectId).toList();
      _loading = false;
    });
  }

  // ---------- 新增 / 编辑 ----------
  Future<void> _edit([Contract? c]) async {
    final noCtrl = TextEditingController(text: c?.contractNo ?? '');
    final targetCtrl = TextEditingController(text: c?.target ?? '');
    final amountCtrl = TextEditingController(
        text: c != null && c.amount > 0 ? (c.amount / 100).toStringAsFixed(2) : '');
    final noteCtrl = TextEditingController(text: c?.note ?? '');
    var status = c?.status ?? ContractStatus.draft;
    var signedAt = c?.signedAt ?? DateTime.now().millisecondsSinceEpoch;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(c == null ? L10n.instance.t('contract_new') : L10n.instance.t('contract_edit')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: noCtrl,
                  decoration: InputDecoration(labelText: L10n.instance.t('contract_section_number_label'), hintText: L10n.instance.t('contract_section_e_g')),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: targetCtrl,
                  decoration: InputDecoration(labelText: L10n.instance.t('contract_section_party_label'), hintText: L10n.instance.t('contract_section_contract_party')),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: moneyInputFormatters,
                  decoration: InputDecoration(labelText: L10n.instance.t('i18n_621'), hintText: '0.00'),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: DateTime.fromMillisecondsSinceEpoch(signedAt),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setDlg(() => signedAt = picked.millisecondsSinceEpoch);
                    }
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(labelText: L10n.instance.t('i18n_520')),
                    child: Text(DateFormat('yyyy-MM-dd')
                        .format(DateTime.fromMillisecondsSinceEpoch(signedAt))),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ContractStatus>(
                  initialValue: status,
                  decoration: InputDecoration(labelText: L10n.instance.t('common_status')),
                  items: ContractStatus.values
                      .map((s) => DropdownMenuItem(value: s, child: Text(s.label)))
                      .toList(),
                  onChanged: (v) => setDlg(() => status = v ?? status),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  maxLength: 300,
                  decoration: InputDecoration(labelText: L10n.instance.t('common_note_optional')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () => targetCtrl.text.trim().isEmpty
                  ? null
                  : Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('common_save')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (c == null) {
      await AppDb.instance.insertContract(Contract(
        target: targetCtrl.text.trim(),
        amount: Money.parseYuanToFen(amountCtrl.text.trim()),
        projectId: widget.projectId,
        status: status,
        signedAt: signedAt,
        contractNo: noCtrl.text.trim(),
        note: noteCtrl.text.trim(),
        updatedAt: now,
      ));
    } else {
      await AppDb.instance.updateContract(c.copyWith(
        target: targetCtrl.text.trim(),
        amount: Money.parseYuanToFen(amountCtrl.text.trim()),
        status: status,
        signedAt: signedAt,
        contractNo: noCtrl.text.trim(),
        note: noteCtrl.text.trim(),
      ));
    }
    Ticker.ping();
    await _load();
  }

  Future<void> _delete(Contract c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('contract_delete')),
        content: Text(L10n.instance.t('contract_delete_confirm', args: {'c.contractNo.isEmpty ? c.target : c.contractNo': c.contractNo.isEmpty ? c.target : c.contractNo})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.deleteContract(c.id!);
    Ticker.ping();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(L10n.instance.t('common_contract'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            TextButton.icon(
              onPressed: _edit,
              icon: Icon(Icons.add, size: 18),
              label: Text(L10n.instance.t('contract_new')),
            ),
          ],
        ),
        if (_loading)
          AppLoading(size: 22)
        else if (_contracts.isEmpty)
          AppEmpty(
            icon: Icons.description_outlined,
            title: L10n.instance.t('contract_empty'),
            hint: L10n.instance.t('i18n_486'),
          )
        else
          ..._contracts.map((c) => Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.description_outlined, color: AppTheme.primary),
                      title: Text(
                        c.contractNo.isEmpty ? c.target : '${c.contractNo} · ${c.target}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '¥${_fmt.format(c.amount / 100)} · ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(c.signedAt))}'
                        '${c.note.isEmpty ? '' : '\n${c.note}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StatusBadge(status: c.status),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18, color: AppTheme.textSub),
                            onPressed: () => _edit(c),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textSub),
                            onPressed: () => _delete(c),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: AttachmentSection(ownerType: 'contract', ownerId: c.id!),
                    ),
                  ],
                ),
              )),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final ContractStatus status;
const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final map = {
      ContractStatus.draft: (AppTheme.textSub, Icons.edit_note),
      ContractStatus.signed: (AppTheme.accent, Icons.how_to_reg_outlined),
      ContractStatus.done: (AppTheme.primary, Icons.check_circle_outline),
    };
    final (color, icon) = map[status]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sheet),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(status.label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
