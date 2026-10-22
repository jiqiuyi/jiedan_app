import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../constants.dart';
import '../theme.dart';
import '../state/ticker.dart';
import '../widgets/payment_dialog.dart';
import '../widgets/show_payment_code.dart';
import '../services/notify_service.dart';
import '../widgets/attachment_section.dart';
import '../widgets/contract_section.dart';
import 'quote_page.dart';
import '../utils/money_input.dart';
import '../widgets/app_ui.dart';

class ProjectDetailPage extends StatefulWidget {
  final Project project;
  final String customerName;
const   ProjectDetailPage({super.key, required this.project, required this.customerName});

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  late Project _project;
  List<Payment> _payments = [];
  List<Milestone> _milestones = [];
  List<ProjectCost> _costs = [];
  int _paidTotal = 0; // 分
  int _costTotal = 0; // 分
  bool _loading = true;
  final _fmt = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _load();
  }

  Future<void> _load() async {
    final db = AppDb.instance;
    final payments = await db.getPayments(_project.id!);
    final paid = await db.projectPaidTotal(_project.id!);
    final milestones = await db.getMilestones(_project.id!);
    final costs = await db.getProjectCosts(_project.id!);
    if (!mounted) return;
    setState(() {
      _payments = payments;
      _paidTotal = paid;
      _milestones = milestones;
      _costs = costs;
      _costTotal = costs.fold<int>(0, (s, c) => s + c.amount);
      _loading = false;
    });
  }

  // 添加项目成本（成本名称=成本标签快照 + 金额元→分）
  Future<void> _addCost() async {
    final costTags = await AppDb.instance.getTagItems('cost');
    if (!mounted) return;
    if (costTags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('common_no_cost_tag'))),
      );
      return;
    }
    final amountCtrl = TextEditingController();
    String selected = costTags.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(L10n.instance.t('project_add_cost')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_334')),
                items: costTags.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                onChanged: (v) => setDlg(() => selected = v ?? selected),
              ),
              SizedBox(height: 12),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: moneyInputFormatters,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_621'), hintText: '0.00'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () => Money.parseYuanToFen(amountCtrl.text.trim()) <= 0
                  ? null
                  : Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('common_save')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await AppDb.instance.insertProjectCost(ProjectCost(
        projectId: _project.id!,
        name: selected,
        amount: Money.parseYuanToFen(amountCtrl.text.trim()),
        createdAt: now,
        updatedAt: now,
      ));
      Ticker.ping();
      await _load();
    }
  }

  Future<void> _deleteCost(ProjectCost c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('project_delete_cost')),
        content: Text(L10n.instance.t('project_delete_cost_confirm', args: {'c.name': c.name, '_fmt.format(c.amount / 100)': _fmt.format(c.amount / 100)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.deleteProjectCost(c.id!);
    Ticker.ping();
    await _load();
  }

  // 状态流转
  Future<void> _advanceStatus() async {
    ProjectStatus next;
    switch (_project.status) {
      case ProjectStatus.accepted:
        next = ProjectStatus.working;
        break;
      case ProjectStatus.working:
        next = ProjectStatus.awaiting;
        break;
      case ProjectStatus.awaiting:
        next = ProjectStatus.done;
        break;
      case ProjectStatus.done:
        next = ProjectStatus.awaiting;
        break;
    }
    final updated = _project.copyWith(status: next, updatedAt: DateTime.now().millisecondsSinceEpoch);
    await AppDb.instance.updateProject(updated);
    Ticker.ping();
    setState(() => _project = updated);
  }

  Future<void> _addPayment() async {
    final ok = await showPaymentDialog(
      context,
      projectId: _project.id!,
      amountTotal: _project.amountTotal,
      paidTotal: _paidTotal,
    );
    if (ok) await _load();
  }

  Future<void> _deletePayment(Payment p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('project_delete_payment')),
        content: Text(
            L10n.instance.t('i18n_505', args: {'v0': _fmt.format(p.amount / 100)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.deletePayment(p.id!);
    Ticker.ping();
    await _load();
  }

  /// 项目详情收款入口：选渠道 → 展示收款码 → 手动确认到账
  Future<void> _collectPayment() async {
    final ok = await showProjectCollectSheet(
      context,
      projectId: _project.id!,
      projectTitle: _project.title,
      amountTotal: _project.amountTotal,
      paidTotal: _paidTotal,
    );
    if (ok) await _load();
  }

  Future<void> _deleteProject() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('project_delete')),
        content: Text(L10n.instance.t('project_delete_confirm2')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteProject(_project.id!);
      Ticker.ping();
      if (mounted) Navigator.pop(context);
    }
  }

  // ================= 项目跟进：进度 % / 交付时间（v1.24.0） =================
  Future<void> _editProgress() async {
    var progress = _project.progress;
    var deliverDate = _project.deliverDate;
    final progressCtrl = TextEditingController(text: progress.toString());
    final fmt = DateFormat('yyyy-MM-dd');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDlg) => AlertDialog(
          title: Text(L10n.instance.t('project_detail_page_project_progress')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.instance.t('project_detail_page_progress'), style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: progress.toDouble().clamp(0, 100),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      label: '$progress%',
                      onChanged: (v) {
                        setDlg(() {
                          progress = v.round();
                          progressCtrl.text = progress.toString();
                        });
                      },
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    child: TextField(
                      controller: progressCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        isDense: true,
                        suffixText: '%',
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        setDlg(() => progress = (n ?? 0).clamp(0, 100));
                      },
                    ),
                  ),
                ],
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Text(L10n.instance.t('project_delivery_date'), style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
                  Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final initial = deliverDate > 0
                          ? DateTime.fromMillisecondsSinceEpoch(deliverDate)
                          : DateTime(now.year, now.month, now.day);
                      final picked = await showDatePicker(
                        context: dctx,
                        initialDate: initial,
                        firstDate: DateTime(now.year - 1, 1, 1),
                        lastDate: DateTime(now.year + 5, 12, 31),
                        helpText: L10n.instance.t('i18n_605'),
                      );
                      if (picked != null) setDlg(() => deliverDate = picked.millisecondsSinceEpoch);
                    },
                    icon: Icon(Icons.event_outlined, size: 18),
                    label: Text(
                      deliverDate > 0 ? fmt.format(DateTime.fromMillisecondsSinceEpoch(deliverDate)) : L10n.instance.t('i18n_446'),
                    ),
                  ),
                  if (deliverDate > 0)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close, size: 16, color: AppTheme.textSub),
                      onPressed: () => setDlg(() => deliverDate = 0),
                    ),
                ],
              ),
              SizedBox(height: 4),
              Text(L10n.instance.t('project_detail_page_the_list'),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx, false), child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(progressCtrl.text.trim());
                if (n != null) progress = n.clamp(0, 100);
                Navigator.pop(dctx, true);
              },
              child: Text(L10n.instance.t('common_save')),
            ),
          ],
        ),
      ),
    );
    progressCtrl.dispose();
    if (saved != true || !mounted) return;
    final updated = _project.copyWith(
      progress: progress,
      deliverDate: deliverDate,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDb.instance.updateProject(updated);
    Ticker.ping();
    if (!mounted) return;
    setState(() => _project = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('project_detail_page_progress_updated'))),
    );
  }

  // ================= 里程碑 / 阶段管理（v1.10.0） =================
  Future<void> _addMilestone() async {
    await _showMilestoneDialog();
  }

  Future<void> _editMilestone(Milestone ms) async {
    await _showMilestoneDialog(ms);
  }

  // 新增 / 编辑阶段共用弹窗：新增时 existing 为 null；编辑时预填名称 / 金额 / 到期日期。
  Future<void> _showMilestoneDialog([Milestone? existing]) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final amountCtrl = TextEditingController(
        text: existing != null && existing.amount > 0 ? (existing.amount / 100).toString() : '');
    var dueDate = existing?.dueDate ?? 0;
    final fmt = DateFormat('yyyy-MM-dd');
    await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(existing == null ? L10n.instance.t('project_add_milestone') : L10n.instance.t('project_edit_milestone')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: InputDecoration(labelText: L10n.instance.t('project_detail_stage_label'), hintText: L10n.instance.t('project_detail_page_e_g')),
              ),
              SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: moneyInputFormatters,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_627')),
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Text(L10n.instance.t('project_due_date'), style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
                  Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final initial = dueDate > 0
                          ? DateTime.fromMillisecondsSinceEpoch(dueDate)
                          : DateTime(now.year, now.month, now.day);
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: initial,
                        firstDate: DateTime(now.year - 1, 1, 1),
                        lastDate: DateTime(now.year + 5, 12, 31),
                        helpText: L10n.instance.t('i18n_606'),
                      );
                      if (picked != null) setDlg(() => dueDate = picked.millisecondsSinceEpoch);
                    },
                    icon: Icon(Icons.event_outlined, size: 18),
                    label: Text(
                      dueDate > 0 ? fmt.format(DateTime.fromMillisecondsSinceEpoch(dueDate)) : L10n.instance.t('i18n_446'),
                    ),
                  ),
                  if (dueDate > 0)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close, size: 16, color: AppTheme.textSub),
                      onPressed: () => setDlg(() => dueDate = 0),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final amount = (double.tryParse(amountCtrl.text.trim()) ?? 0) * 100;
                if (name.isEmpty) return;
                Navigator.pop(ctx, true);
                if (existing == null) {
                  AppDb.instance.insertMilestone(Milestone(
                    projectId: _project.id!,
                    name: name,
                    amount: amount.round(),
                    dueDate: dueDate,
                    createdAt: DateTime.now().millisecondsSinceEpoch,
                  )).then((_) => _load());
                } else {
                  AppDb.instance.updateMilestone(
                      existing.copyWith(name: name, amount: amount.round(), dueDate: dueDate)).then((_) => _load());
                }
              },
              child: Text(L10n.instance.t('common_save')),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    amountCtrl.dispose();
  }

  Future<void> _toggleMilestone(Milestone ms) async {
    await AppDb.instance.updateMilestone(ms.copyWith(done: !ms.done));
    await _load();
  }

  Future<void> _deleteMilestone(Milestone ms) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('project_delete_milestone')),
        content: Text(L10n.instance.t('i18n_506', args: {'v0': ms.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteMilestone(ms.id!);
      await _load();
    }
  }

  // ================= 催款提醒（v1.10.0，本地通知） =================
  Future<void> _setReminder() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, now.month, now.day).add(Duration(days: 7)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 3, 12, 31),
      helpText: L10n.instance.t('i18n_611'),
    );
    if (picked == null || !mounted) return;
    final when = DateTime(picked.year, picked.month, picked.day, 9, 0);
    final remaining = _project.amountTotal - _paidTotal < 0
        ? 0
        : _project.amountTotal - _paidTotal;
    await NotifyService.instance.scheduleProjectReminder(
      projectId: _project.id!,
      projectName: _project.title,
      amountYuan: _fmt.format(remaining / 100),
      when: when,
    );
    final updated = _project.copyWith(
      dueDate: when.millisecondsSinceEpoch,
      remindAt: when.millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDb.instance.updateProject(updated);
    if (!mounted) return;
    setState(() => _project = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('project_detail_page_reminder_set', args: {'date': DateFormat('yyyy-MM-dd').format(when)}))),
    );
  }

  Future<void> _cancelReminder() async {
    await NotifyService.instance.cancelProjectReminder(_project.id!);
    final updated = _project.copyWith(
      dueDate: 0,
      remindAt: 0,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await AppDb.instance.updateProject(updated);
    if (!mounted) return;
    setState(() => _project = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('project_reminder_cancelled'))),
    );
  }

  // ================= 里程碑 / 催款提醒 UI =================
  Widget _buildProgressBody() {
    final hasDeliver = _project.deliverDate > 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isOverdue = hasDeliver && _project.deliverDate < nowMs;
    final isNear =
        hasDeliver && !isOverdue && (_project.deliverDate - nowMs) < 3 * 24 * 3600 * 1000;
    final deliverColor = isOverdue ? AppTheme.danger : (isNear ? AppTheme.warn : AppTheme.textMain);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(L10n.instance.t('common_progress'), style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
            Spacer(),
            Text('${_project.progress}%',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ],
        ),
        SizedBox(height: 6),
        LinearProgressIndicator(
          value: (_project.progress / 100).clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
          color: AppTheme.primary,
          borderRadius: BorderRadius.circular(AppRadius.xxs),
        ),
        SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.event_outlined, size: 16, color: AppTheme.textSub),
            SizedBox(width: 6),
            Text(
              hasDeliver
                  ? '${L10n.instance.t('pd_deliver_time')} ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(_project.deliverDate))}${isOverdue ? L10n.instance.t('pd_overdue') : (isNear ? L10n.instance.t('pd_near') : '')}'
                  : L10n.instance.t('i18n_447'),
              style: TextStyle(fontSize: 13, color: deliverColor),
            ),
          ],
        ),
        SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _editProgress,
          icon: Icon(Icons.tune, size: 18),
          label: Text(L10n.instance.t('project_edit_progress')),
        ),
      ],
    );
  }

  Widget _buildMilestoneBody() {
    if (_milestones.isEmpty) {
      return Row(
        children: [
          Icon(Icons.flag_outlined, size: 18, color: AppTheme.textSub),
          SizedBox(width: 8),
          Expanded(child: Text(L10n.instance.t('project_no_milestones'), style: TextStyle(color: AppTheme.textSub, fontSize: 13))),
        ],
      );
    }
    final totalAmount = _milestones.fold<int>(0, (s, m) => s + m.amount);
    final doneAmount = _milestones.where((m) => m.done).fold<int>(0, (s, m) => s + m.amount);
    final progress = totalAmount <= 0 ? 0.0 : doneAmount / totalAmount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(L10n.instance.t('project_milestone_progress'), style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
            Spacer(),
            Text('${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ],
        ),
        SizedBox(height: 6),
        LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
          color: AppTheme.primary,
          borderRadius: BorderRadius.circular(AppRadius.xxs),
        ),
        SizedBox(height: 4),
        Text(L10n.instance.t('project_milestone_amount_line', args: {'doneAmount / 100': '${doneAmount / 100}', 'totalAmount / 100': '${totalAmount / 100}'}),
            style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
        SizedBox(height: 8),
        ..._milestones.map((m) => CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: m.done,
              onChanged: (_) => _toggleMilestone(m),
              title: Text(m.name,
                  style: TextStyle(
                    decoration: m.done ? TextDecoration.lineThrough : null,
                    color: m.done ? AppTheme.textSub : null,
                  )),
              subtitle: Text('¥${_fmt.format(m.amount / 100)}${m.dueDate > 0 ? L10n.instance.t('pd_due_suffix', args: {'v0': DateFormat('MM-dd').format(DateTime.fromMillisecondsSinceEpoch(m.dueDate))}) : ''}',
                  style: TextStyle(fontSize: 12)),
              secondary: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(Icons.edit_outlined, size: 18, color: AppTheme.textSub),
                    onPressed: () => _editMilestone(m),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 18, color: AppTheme.textSub),
                    onPressed: () => _deleteMilestone(m),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  Widget _buildReminderBody() {
    final remaining = _project.amountTotal - _paidTotal < 0
        ? 0
        : _project.amountTotal - _paidTotal;
    final hasReminder = _project.dueDate > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(L10n.instance.t('i18n_321', args: {'v0': _fmt.format(remaining / 100)}),
            style: TextStyle(fontSize: 13, color: AppTheme.warn)),
        SizedBox(height: 4),
        Text(
          hasReminder
              ? '${L10n.instance.t('pd_due_date')} ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(_project.dueDate))}${L10n.instance.t('pd_local_notify_note')}'
              : L10n.instance.t('i18n_562'),
          style: TextStyle(fontSize: 13, color: AppTheme.textSub),
        ),
        SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _setReminder,
              icon: Icon(Icons.event, size: 18),
              label: Text(hasReminder ? L10n.instance.t('project_change_due') : L10n.instance.t('project_set_due')),
            ),
            if (hasReminder) ...[
              SizedBox(width: 8),
              TextButton.icon(
                onPressed: _cancelReminder,
                icon: Icon(Icons.notifications_off_outlined, size: 18),
                label: Text(L10n.instance.t('project_cancel_reminder')),
              ),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _project.amountTotal - _paidTotal < 0
        ? 0
        : _project.amountTotal - _paidTotal;
    final progress = _project.amountTotal <= 0
        ? 0.0
        : (_paidTotal / _project.amountTotal);
    return Scaffold(
      appBar: AppBar(
        title: Text(_project.title),
        actions: [
          IconButton(
            tooltip: L10n.instance.t('quote_title'),
            icon: Icon(Icons.receipt_long_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => QuotePage(
                    initialProjectId: _project.id,
                    initialTitle: _project.title,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? AppLoading()
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_project.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                                  SizedBox(height: 6),
                                  Text(L10n.instance.t('project_detail_page_customer', args: {'widget.customerName': widget.customerName}), style: const TextStyle(color: AppTheme.textSub)),
                                ],
                              ),
                            ),
                            _StatusBadge(status: _project.status),
                          ],
                        ),
                        SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                          color: AppTheme.accent,
                          borderRadius: BorderRadius.circular(AppRadius.xxs),
                        ),
                        SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _Amount(col: AppTheme.textSub, label: L10n.instance.t('project_agreed_total'), value: '¥${_fmt.format(_project.amountTotal / 100)}'),
                            _Amount(col: AppTheme.accent, label: L10n.instance.t('project_received'), value: '¥${_fmt.format(_paidTotal / 100)}'),
                            _Amount(col: AppTheme.warn, label: L10n.instance.t('project_pending'), value: '¥${_fmt.format(remaining / 100)}'),
                          ],
                        ),
                        SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: _advanceStatus,
                          icon: Icon(Icons.arrow_forward),
                          label: Text(L10n.instance.t('project_go_next', args: {'_nextLabel()': _nextLabel()})),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_project.note.isNotEmpty) ...[
                  Padding(
                    padding: EdgeInsets.fromLTRB(18, 10, 18, 4),
                    child: Text(L10n.instance.t('project_notes'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_project.note, style: TextStyle(fontSize: 14, height: 1.5)),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.instance.t('project_milestones'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                      TextButton.icon(
                        onPressed: _addMilestone,
                        icon: Icon(Icons.add, size: 18),
                        label: Text(L10n.instance.t('project_add_milestone')),
                      ),
                    ],
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildMilestoneBody(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.instance.t('project_progress_delivery'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                      Icon(Icons.flag_outlined, size: 18, color: AppTheme.textSub),
                    ],
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildProgressBody(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.instance.t('project_reminder'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                      Icon(Icons.notifications_outlined, size: 18, color: AppTheme.textSub),
                    ],
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildReminderBody(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.instance.t('project_payment_records'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                      TextButton.icon(
                        onPressed: _collectPayment,
                        icon: Icon(Icons.payments_outlined, size: 18),
                        label: Text(L10n.instance.t('common_collect')),
                      ),
                      TextButton.icon(onPressed: _addPayment, icon: Icon(Icons.add, size: 18), label: Text(L10n.instance.t('project_record_payment'))),
                    ],
                  ),
                ),
                if (_payments.isEmpty)
                  AppEmpty(
                    icon: Icons.receipt_long_outlined,
                    title: L10n.instance.t('project_detail_page_no_payment'),
                  )
                else
                  ..._payments.map((p) => Card(
                        child: ListTile(
                          leading: Icon(Icons.account_balance_wallet_outlined, color: AppTheme.accent),
                          title: Text('¥${_fmt.format(p.amount / 100)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${p.displayType} · ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(p.paidAt))}${p.note.isEmpty ? '' : ' · ${p.note}'}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textSub),
                            onPressed: () => _deletePayment(p),
                          ),
                        ),
                      )),
                SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ContractSection(projectId: _project.id!),
                  ),
                ),
                SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.instance.t('project_costs'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                      Text(L10n.instance.t('i18n_165', args: {'v0': _fmt.format(_costTotal / 100)}),
                          style: TextStyle(fontSize: 13, color: AppTheme.warn, fontWeight: FontWeight.w700)),
                      TextButton.icon(
                        onPressed: _addCost,
                        icon: Icon(Icons.add, size: 18),
                        label: Text(L10n.instance.t('project_add_cost')),
                      ),
                    ],
                  ),
                ),
                if (_costs.isEmpty)
                  AppEmpty(
                    icon: Icons.account_balance_outlined,
                    title: L10n.instance.t('project_detail_page_no_cost'),
                  )
                else
                  ..._costs.map((c) => Card(
                        child: ListTile(
                          leading: Icon(Icons.shopping_cart_outlined, color: AppTheme.warn),
                          title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('¥${_fmt.format(c.amount / 100)} · ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(c.createdAt))}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textSub),
                            onPressed: () => _deleteCost(c),
                          ),
                        ),
                      )),
                SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: AttachmentSection(ownerType: 'project', ownerId: _project.id!),
                  ),
                ),
                SizedBox(height: 12),
                AppButton(
                  label: L10n.instance.t('project_delete'),
                  icon: Icons.delete_outline,
                  kind: AppButtonKind.dangerOutline,
                  size: AppButtonSize.medium,
                  expand: false,
                  onPressed: _deleteProject,
                ),
              ],
            ),
    );
  }

  String _nextLabel() {
    switch (_project.status) {
      case ProjectStatus.accepted:
        return L10n.instance.t('constants_in_progress');
      case ProjectStatus.working:
        return L10n.instance.t('project_detail_page_pending_final');
      case ProjectStatus.awaiting:
        return L10n.instance.t('constants_completed');
      case ProjectStatus.done:
        return L10n.instance.t('i18n_317');
    }
  }
}

class _Amount extends StatelessWidget {
  final Color col;
  final String label;
  final String value;
const _Amount({required this.col, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: col)),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final ProjectStatus status;
const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final map = {
      ProjectStatus.accepted: (AppTheme.primary, Icons.mark_email_read_outlined),
      ProjectStatus.working: (AppTheme.accent, Icons.build_outlined),
      ProjectStatus.awaiting: (AppTheme.warn, Icons.schedule),
      ProjectStatus.done: (AppTheme.textSub, Icons.check_circle_outline),
    };
    final (color, icon) = map[status]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(AppRadius.sheet)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(status.label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
