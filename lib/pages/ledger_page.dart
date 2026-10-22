import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../theme.dart';

/// 日常记账首页（v23）：月份切换、本月支出/收入/结余统计卡片、
/// 按 entry_date 倒序分组明细列表；右上角新增走完整记账表单弹窗。
class LedgerPage extends StatefulWidget {
const   LedgerPage({super.key});

  @override
  State<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<LedgerPage> {
  final AppDb _db = AppDb.instance;
  List<LedgerEntry> _entries = [];
  List<Project> _projects = [];
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _month = DateTime(DateTime.now().year, DateTime.now().month);
    _reload();
  }

  Future<void> _reload() async {
    final entries = await _db.getLedgerEntries();
    final projects = await _db.getProjects();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _projects = projects;
    });
  }

  List<LedgerEntry> get _monthEntries {
    final start = _month.millisecondsSinceEpoch;
    final end = DateTime(_month.year, _month.month + 1).millisecondsSinceEpoch;
    return _entries
        .where((e) => e.entryDate >= start && e.entryDate < end)
        .toList();
  }

  int get _totalExpense =>
      _monthEntries.where((e) => e.kind == 0).fold(0, (s, e) => s + e.amount);
  int get _totalIncome =>
      _monthEntries.where((e) => e.kind == 1).fold(0, (s, e) => s + e.amount);

  void _prevMonth() =>
      setState(() => _month = DateTime(_month.year, _month.month - 1));

  void _nextMonth() {
    final now = DateTime.now();
    final next = DateTime(_month.year, _month.month + 1);
    if (next.isAfter(DateTime(now.year, now.month))) return;
    setState(() => _month = next);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 完整记账表单弹窗（新增/编辑共用），返回 LedgerEntry 或 null（取消）。
  Future<void> _showForm({LedgerEntry? entry}) async {
    final result = await showDialog<LedgerEntry>(
      context: context,
      builder: (_) => _LedgerFormDialog(entry: entry, projects: _projects),
    );
    if (result == null || !mounted) return;
    if (entry == null) {
      await _db.insertLedgerEntry(result);
      _toast(L10n.instance.t('i18n_256'));
    } else {
      await _db.updateLedgerEntry(result);
      _toast(L10n.instance.t('i18n_283'));
    }
    _reload();
  }

  Future<void> _confirmDelete(LedgerEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('ledger_delete_record')),
        content: Text(L10n.instance.t('ledger_delete_record_desc', args: {'entry.category': entry.category, '_fmtMoney(entry.amount)': _fmtMoney(entry.amount)})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.instance.t('common_cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_delete'), style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _db.deleteLedgerEntry(entry.id!);
      _toast(L10n.instance.t('i18n_263'));
      _reload();
    }
  }

  String _fmtMoney(int fen) {
    final neg = fen < 0;
    final s = '¥${(fen.abs() / 100).toStringAsFixed(2)}';
    return neg ? '-$s' : s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.instance.t('common_ledger')),
        actions: [
          IconButton(
            icon: Icon(Icons.add_circle_outline),
            tooltip: L10n.instance.t('ledger_add'),
            onPressed: () => _showForm(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildMonthBar(),
          _buildStatsCard(),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildMonthBar() {
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: _prevMonth,
            icon: Icon(Icons.chevron_left),
            tooltip: L10n.instance.t('common_last_month'),
          ),
          Expanded(
            child: Text(
              L10n.instance.t('i18n_016', args: {'v0':'${_month.year}', 'v1':'${_month.month}'}),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            onPressed: isCurrent ? null : _nextMonth,
            icon: Icon(Icons.chevron_right),
            tooltip: L10n.instance.t('common_next_month'),
          ),
          TextButton(
            onPressed: isCurrent
                ? null
                : () => setState(() {
                      _month = DateTime(now.year, now.month);
                    }),
            child: Text(L10n.instance.t('common_this_month')),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    final income = _totalIncome;
    final expense = _totalExpense;
    final balance = income - expense;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          _StatCard(label: L10n.instance.t('common_expense'), value: _fmtMoney(expense), color: AppTheme.danger, flex: 2),
          SizedBox(width: 10),
          _StatCard(label: L10n.instance.t('common_income'), value: _fmtMoney(income), color: AppTheme.success, flex: 2),
          SizedBox(width: 10),
          _StatCard(label: L10n.instance.t('common_balance'), value: _fmtMoney(balance), color: balance < 0 ? AppTheme.danger : AppTheme.primary, flex: 2),
        ],
      ),
    );
  }

  Widget _buildList() {
    final list = _monthEntries;
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined, size: 56, color: AppTheme.textSub.withValues(alpha: 0.4)),
            SizedBox(height: 10),
            Text(L10n.instance.t('ledger_empty'), style: TextStyle(color: AppTheme.textSub)),
            SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => _showForm(),
              icon: Icon(Icons.add),
              label: Text(L10n.instance.t('ledger_add')),
            ),
          ],
        ),
      );
    }

    // 按 entry_date 降序分组：日期头 + 该日条目
    final groups = <DateTime, List<LedgerEntry>>{};
    final sorted = [...list]..sort((a, b) => b.entryDate.compareTo(a.entryDate));
    for (final e in sorted) {
      final day = DateTime.fromMillisecondsSinceEpoch(e.entryDate);
      final key = DateTime(day.year, day.month, day.day);
      groups.putIfAbsent(key, () => []).add(e);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 20),
      itemCount: keys.length,
      itemBuilder: (context, i) {
        final day = keys[i];
        final items = groups[day]!;
        final header =
            '${DateFormat(L10n.instance.t('fmt_md')).format(day)} ${_weekday(day.weekday)}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(header,
                      style: TextStyle(fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w600)),
                  Text(_dayTotal(items), style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
                ],
              ),
            ),
            ...items.map((e) => _buildItem(e)),
          ],
        );
      },
    );
  }

  String _weekday(int w) =>
      [L10n.instance.t('i18n_176'), L10n.instance.t('i18n_178'), L10n.instance.t('i18n_177'), L10n.instance.t('i18n_181'), L10n.instance.t('i18n_179'), L10n.instance.t('i18n_180'), L10n.instance.t('i18n_182')][w - 1];

  String _dayTotal(List<LedgerEntry> items) {
    final ex = items.where((e) => e.kind == 0).fold(0, (s, e) => s + e.amount);
    final inc = items.where((e) => e.kind == 1).fold(0, (s, e) => s + e.amount);
    final parts = <String>[];
    if (ex > 0) parts.add(L10n.instance.t('i18n_376', args: {'v0': _fmtMoney(ex)}));
    if (inc > 0) parts.add(L10n.instance.t('i18n_377', args: {'v0': _fmtMoney(inc)}));
    return parts.isEmpty ? '' : parts.join(' · ');
  }

  Widget _buildItem(LedgerEntry e) {
    final isExpense = e.kind == 0;
    final color = isExpense ? AppTheme.danger : AppTheme.success;
    String? projectName;
    for (final p in _projects) {
      if (p.id == e.projectId) {
        projectName = p.title;
        break;
      }
    }
    final subtitle = [
      if (e.note.isNotEmpty) e.note,
      if (projectName != null) L10n.instance.t('i18n_636', args: {'v0': projectName}),
    ].join(' · ');
    return ListTile(
      dense: true,
      onTap: () => _showActions(e),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: 0.12),
        child: Text(
          e.category.isEmpty ? '' : e.category.substring(0, 1),
          style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      title: Text(e.category, style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        isExpense ? '-${_fmtMoney(e.amount)}' : '+${_fmtMoney(e.amount)}',
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15),
      ),
    );
  }

  Future<void> _showActions(LedgerEntry e) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${e.category} ${_fmtMoney(e.amount)}',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(DateFormat(L10n.instance.t('ledger_date_time_format')).format(
                  DateTime.fromMillisecondsSinceEpoch(e.entryDate))),
            ),
            Divider(height: 1),
            ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text(L10n.instance.t('common_edit')),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppTheme.danger),
              title: Text(L10n.instance.t('common_delete'), style: TextStyle(color: AppTheme.danger)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (act == 'edit') {
      await _showForm(entry: e);
    } else if (act == 'delete') {
      await _confirmDelete(e);
    }
  }
}

/// 完整记账表单弹窗：分类、金额、日期（默认今天）、备注；「项目支出」可选关联项目。
class _LedgerFormDialog extends StatefulWidget {
const _LedgerFormDialog({required this.entry, required this.projects});

  final LedgerEntry? entry;
  final List<Project> projects;

  @override
  State<_LedgerFormDialog> createState() => _LedgerFormDialogState();
}

class _LedgerFormDialogState extends State<_LedgerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late int _kind;
  late String _category;
  late TextEditingController _amountCtrl;
  late TextEditingController _noteCtrl;
  late DateTime _date;
  int? _projectId;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _kind = e?.kind ?? 0;
    _category = e?.category ?? AppConfig.LEDGER_CATEGORIES.first;
    _amountCtrl = TextEditingController(
        text: e == null ? '' : (e.amount / 100).toStringAsFixed(2));
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    _date = e == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(e.entryDate);
    _projectId = (e != null && e.projectId > 0) ? e.projectId : null;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final fen = (double.parse(_amountCtrl.text.trim()) * 100).round();
    if (fen <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('ledger_amount_positive'))));
      return;
    }
    final day = DateTime(_date.year, _date.month, _date.day);
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = LedgerEntry(
      id: widget.entry?.id,
      amount: fen,
      kind: _kind,
      category: _category,
      note: _noteCtrl.text.trim(),
      projectId: (_category == L10n.instance.t('ledger_cat_project') && _projectId != null)
          ? _projectId!
          : 0,
      entryDate: day.millisecondsSinceEpoch,
      createdAt: widget.entry?.createdAt ?? now,
      updatedAt: now,
    );
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? L10n.instance.t('ledger_add') : L10n.instance.t('ledger_edit_entry')),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 支出/收入切换
              SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 0, label: Text(L10n.instance.t('common_expense'))),
                  ButtonSegment(value: 1, label: Text(L10n.instance.t('common_income'))),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              SizedBox(height: 14),
              // 分类
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: AppConfig.LEDGER_CATEGORIES.map((c) {
                  final selected = _category == c;
                  return ChoiceChip(
                    label: Text(L10n.instance.t(AppConfig.ledgerCatKey(c))),
                    selected: selected,
                    onSelected: (_) => setState(() => _category = c),
                    selectedColor: AppTheme.primary.withValues(alpha: 0.12),
                    labelStyle: TextStyle(
                      color: selected ? AppTheme.primary : AppTheme.textMain,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  );
                }).toList(),
              ),
              // 项目支出：可选关联项目
              if (_category == L10n.instance.t('ledger_cat_project')) ...[
                SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _projectId,
                  decoration: InputDecoration(
                    labelText: L10n.instance.t('quote_link_project_optional'),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: widget.projects.isEmpty
                      ? [
                          DropdownMenuItem(value: 0, child: Text(L10n.instance.t('common_no_projects'))),
                        ]
                      : widget.projects
                          .map((p) => DropdownMenuItem(
                              value: p.id!, child: Text(p.title, overflow: TextOverflow.ellipsis)))
                          .toList(),
                  onChanged: (v) => setState(() => _projectId = v),
                ),
              ],
              SizedBox(height: 12),
              // 金额
              TextFormField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: L10n.instance.t('i18n_621'),
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                validator: (v) {
                  final val = double.tryParse((v ?? '').trim());
                  if (val == null || val <= 0) return L10n.instance.t('i18n_583');
                  return null;
                },
              ),
              SizedBox(height: 12),
              // 日期
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: L10n.instance.t('common_date'),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(DateFormat(L10n.instance.t('ledger_date_format')).format(_date)),
                      const Icon(Icons.calendar_today_outlined, size: 16),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 备注
              TextField(
                controller: _noteCtrl,
                maxLength: 50,
                decoration: InputDecoration(
                  labelText: L10n.instance.t('common_note_optional'),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.instance.t('common_cancel')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(L10n.instance.t('common_save')),
        ),
      ],
    );
  }
}

/// 统计卡片。
class _StatCard extends StatelessWidget {
const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.flex,
  });

  final String label;
  final String value;
  final Color color;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            const SizedBox(height: 4),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }
}
