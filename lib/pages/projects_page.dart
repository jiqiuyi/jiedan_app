import 'dart:async';
import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../widgets/slidable_action.dart';
import '../models.dart';
import '../constants.dart';
import '../app_state.dart';
import '../theme.dart';
import '../state/ticker.dart';
import 'project_detail_page.dart';
import 'paywall_page.dart';
import '../widgets/payment_dialog.dart';
import '../utils/money_input.dart';
import '../widgets/app_ui.dart';
import '../services/error_reporter.dart';

class ProjectsPage extends StatefulWidget {
const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  List<Project> _projects = [];
  List<Customer> _customers = [];
  Map<int, int> _paidTotals = {}; // 项目已收总额（分）
  Map<int, int> _costTotals = {}; // 项目成本合计（分）
  int _tab = 0; // 0=全部, 1..4=状态+1
  String _query = '';
  Timer? _debounce;
  bool _loading = true;
  bool _loadFailed = false;

  final _tabs = [L10n.instance.t('projects_page_all'), L10n.instance.t('common_order'), L10n.instance.t('constants_in_progress'), L10n.instance.t('projects_page_pending_final'), L10n.instance.t('constants_completed')];

  // 订阅全局数据变更广播（删除/新增/状态流转来自详情页等），
  // 返回本列表时自动刷新，避免删除后残留旧数据。
  StreamSubscription<int>? _tickerSub;

  @override
  void initState() {
    super.initState();
    _tickerSub = Ticker.counterStream.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tickerSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // 三态兜底：DB 异常不得让页面停留在无限转圈（_loading 永不置 false），
    // 一律落到「加载失败 + 重试按钮」终态；Ticker 周期后续重试成功会自动恢复。
    try {
      final db = AppDb.instance;
      final projects = await db.getProjects();
      final customers = await db.getCustomers();
      final paidTotals = await db.projectPaidTotals();
      final costTotals = await db.projectCostTotals();
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _customers = customers;
        _paidTotals = paidTotals;
        _costTotals = costTotals;
        _loading = false;
        _loadFailed = false;
      });
    } catch (e, st) {
      ErrorReporter.instance.logError('projects_load', e, st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  // 列表交付截止标记（v1.24.0）：未设交付时间不标记；超期红色 / 3 天内黄色。
  List<Widget> _deliverMark(Project pr) {
    if (pr.deliverDate <= 0) return [];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final overdue = pr.deliverDate < nowMs;
    final near = !overdue && (pr.deliverDate - nowMs) < 3 * 24 * 3600 * 1000;
    final color = overdue ? AppTheme.danger : (near ? AppTheme.warn : AppTheme.textSub);
    return [
      Icon(overdue ? Icons.error_outline : Icons.event_outlined, size: 14, color: color),
      SizedBox(width: 2),
      Text(
        '${L10n.instance.t('projects_deliver')} ${DateFormat('MM-dd').format(DateTime.fromMillisecondsSinceEpoch(pr.deliverDate))}${overdue ? L10n.instance.t('projects_overdue') : (near ? L10n.instance.t('projects_near') : '')}',
        style: TextStyle(fontSize: 12, color: color),
      ),
    ];
  }

  List<Project> get _filtered {
    var list = _projects;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((e) =>
              e.title.toLowerCase().contains(q) ||
              _customerName(e.customerId).toLowerCase().contains(q))
          .toList();
    }
    if (_tab != 0) {
      final s = ProjectStatus.values[_tab - 1];
      list = list.where((e) => e.status == s).toList();
    }
    return list;
  }

  String _customerName(int id) {
    final c = _customers.where((e) => e.id == id).firstOrNull;
    return c?.name ?? L10n.instance.t('i18n_441');
  }

  Future<void> _addProject() async {
    if (!AppState.instance.isPro &&
        _projects.where((e) => e.status != ProjectStatus.done).length >=
            AppConfig.freeProjectLimit) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => PaywallPage(
          title: L10n.instance.t('projects_free_limit', args: {'AppConfig.freeProjectLimit': '${AppConfig.freeProjectLimit}'}),
          desc: L10n.instance.t('i18n_556'),
        ),
      ));
      return;
    }
    final customers = await AppDb.instance.getCustomers();
    if (!mounted) return;
    if (customers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('projects_customer_first'))),
      );
      return;
    }
    if (customers.length != _customers.length) {
      setState(() => _customers = customers);
    }
    final costTags = await AppDb.instance.getTagItems('cost');
    if (!mounted) return;
    final titleCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    // 成本行：名称=成本标签名快照 + 金额输入（元，转分存储）
    final costRows = <({String name, TextEditingController amount})>[];
    int selectedCustomer = customers.first.id!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(L10n.instance.t('projects_new')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: titleCtrl, decoration: InputDecoration(labelText: L10n.instance.t('projects_name_label'), hintText: L10n.instance.t('projects_name_example'))),
                SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: selectedCustomer,
                  decoration: InputDecoration(labelText: L10n.instance.t('i18n_339')),
                  items: customers.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                  onChanged: (v) => setDlg(() => selectedCustomer = v!),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: moneyInputFormatters,
                  decoration: InputDecoration(labelText: L10n.instance.t('i18n_532'), hintText: '0.00'),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  maxLength: 500,
                  decoration: InputDecoration(labelText: L10n.instance.t('common_note_optional'), hintText: L10n.instance.t('projects_desc_hint')),
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Text(L10n.instance.t('common_cost'), style: TextStyle(fontWeight: FontWeight.w600)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(L10n.instance.t('projects_cost_optional'), style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
                    ),
                    if (costTags.isNotEmpty)
                      TextButton.icon(
                        icon: Icon(Icons.add, size: 18),
                        label: Text(L10n.instance.t('common_add')),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: () => setDlg(() => costRows.add((
                          name: costTags.first,
                          amount: TextEditingController(),
                        ))),
                      ),
                  ],
                ),
                if (costTags.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(L10n.instance.t('common_no_cost_tag2'),
                        style: TextStyle(fontSize: 12, color: AppTheme.warn)),
                  ),
                ...costRows.asMap().entries.map((e) {
                  final i = e.key;
                  final row = e.value;
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            initialValue: row.name,
                            isDense: true,
                            decoration: InputDecoration(labelText: L10n.instance.t('i18n_334')),
                            items: costTags
                                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                                .toList(),
                            onChanged: (v) => setDlg(() =>
                                costRows[i] = (name: v ?? row.name, amount: row.amount)),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: row.amount,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: moneyInputFormatters,
                            decoration: InputDecoration(labelText: L10n.instance.t('i18n_621'), hintText: '0.00', isDense: true),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, size: 18),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setDlg(() => costRows.removeAt(i)),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () => titleCtrl.text.trim().isEmpty
                  ? null
                  : Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('common_create')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final projectId = await AppDb.instance.insertProject(Project(
        customerId: selectedCustomer,
        title: titleCtrl.text.trim(),
        status: ProjectStatus.accepted,
        amountTotal: Money.parseYuanToFen(amountCtrl.text.trim()),
        createdAt: now,
        updatedAt: now,
        note: noteCtrl.text.trim(),
      ));
      // 新建项目时一并插入成本行（_insertSync 同步通道，created_at 归属当月）
      for (final row in costRows) {
        final amt = Money.parseYuanToFen(row.amount.text.trim());
        if (amt > 0) {
          await AppDb.instance.insertProjectCost(ProjectCost(
            projectId: projectId,
            name: row.name,
            amount: amt,
            createdAt: now,
            updatedAt: now,
          ));
        }
      }
      Ticker.ping();
      await _load();
    }
  }

  // 左滑「编辑」：改项目名称 / 所属客户 / 约定总额 / 备注
  Future<void> _editProject(Project pr) async {
    final titleCtrl = TextEditingController(text: pr.title);
    final amountCtrl = TextEditingController(
        text: pr.amountTotal > 0 ? (pr.amountTotal / 100).toStringAsFixed(2) : '');
    final noteCtrl = TextEditingController(text: pr.note);
    int selectedCustomer = pr.customerId;
    final customers = await AppDb.instance.getCustomers();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(L10n.instance.t('projects_edit')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titleCtrl, decoration: InputDecoration(labelText: L10n.instance.t('i18n_632'))),
              SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: selectedCustomer,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_339')),
                items: customers.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setDlg(() => selectedCustomer = v!),
              ),
              SizedBox(height: 12),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: moneyInputFormatters,
                decoration: InputDecoration(labelText: L10n.instance.t('i18n_532')),
              ),
              SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(labelText: L10n.instance.t('common_note_optional'), hintText: L10n.instance.t('projects_desc_hint')),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () => titleCtrl.text.trim().isEmpty ? null : Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('common_save')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await AppDb.instance.updateProject(pr.copyWith(
        customerId: selectedCustomer,
        title: titleCtrl.text.trim(),
        amountTotal: Money.parseYuanToFen(amountCtrl.text.trim()),
        note: noteCtrl.text.trim(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      Ticker.ping();
      await _load();
    }
  }

  // 左滑「删除」：级联删除项目及其收款记录
  Future<void> _removeProject(Project pr) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('project_delete')),
        content: Text(L10n.instance.t('i18n_508', args: {'v0': pr.title})),
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
      await AppDb.instance.deleteProject(pr.id!);
      Ticker.ping();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('common_project'))),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: _addProject,
        child: Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              onChanged: (v) {
                // 200ms 防抖
                _debounce?.cancel();
                _debounce = Timer(Duration(milliseconds: 200), () {
                  if (mounted) setState(() => _query = v);
                });
              },
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: L10n.instance.t('projects_search_hint'),
                prefixIcon: Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: AppTheme.textSub.withValues(alpha: 0.05),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              separatorBuilder: (_, _) => SizedBox(width: 6),
              itemBuilder: (ctx, i) {
                final selected = _tab == i;
                return ChoiceChip(
                  label: Text(_tabs[i]),
                  selected: selected,
                  onSelected: (_) => setState(() => _tab = i),
                  selectedColor: AppTheme.primary.withValues(alpha: 0.12),
                  labelStyle: TextStyle(
                    color: selected ? AppTheme.primary : AppTheme.textSub,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _loading
                ? AppLoading()
                : _loadFailed
                    ? AppError(
                        title: L10n.instance.t('common_load_failed'),
                        hint: L10n.instance.t('i18n_453'),
                        onRetry: () {
                          setState(() {
                            _loading = true;
                            _loadFailed = false;
                          });
                          _load();
                        },
                      )
                    : items.isEmpty
                    ? Center(
                        child: Text(
                          _projects.isEmpty || _query.trim().isNotEmpty
                              ? L10n.instance.t('i18n_482')
                              : L10n.instance.t('i18n_597'),
                          style: TextStyle(color: AppTheme.textSub),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 90),
                        itemCount: items.length,
                        // 卡片高度随内容自适应，保证左滑操作区与卡片严格等高
                        itemBuilder: (ctx, i) {
                          final pr = items[i];
                          final paid = _paidTotals[pr.id] ?? 0;
                          final remaining =
                              pr.amountTotal - paid < 0 ? 0 : pr.amountTotal - paid;
                          return Padding(
                            padding: const EdgeInsets.all(4),
                            child: Slidable(
                              key: ValueKey('prj_${pr.id}'),
                            endActionPane: ActionPane(
                              motion: ScrollMotion(),
                              extentRatio: 0.34,
                              children: [
                                CustomSlidableAction(
                                  onPressed: (_) => _editProject(pr),
                                  backgroundColor: AppTheme.primary,
                                  foregroundColor: Colors.white,
                                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(AppRadius.md)),
                                  child: SlidableActionContent(icon: Icons.edit_outlined, label: L10n.instance.t('common_edit')),
                                ),
                                CustomSlidableAction(
                                  onPressed: (_) => _removeProject(pr),
                                  backgroundColor: AppTheme.danger,
                                  foregroundColor: Colors.white,
                                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(AppRadius.md)),
                                  child: SlidableActionContent(icon: Icons.delete_outline, label: L10n.instance.t('common_delete')),
                                ),
                              ],
                            ),
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => ProjectDetailPage(project: pr, customerName: _customerName(pr.customerId))),
                                  );
                                  await _load();
                                },
                                title: Text(pr.title, style: TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        L10n.instance.t('projects_page_customername_pr', args: {'name': _customerName(pr.customerId), 'amount': NumberFormat('#,##0.00').format(pr.amountTotal / 100)}),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: AppTheme.textSub)),
                                    SizedBox(height: 4),
                                    // 金额行：FittedBox 自动缩放适应宽度，永不换行、不截断
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(text: L10n.instance.t('project_received_pre'), style: TextStyle(color: AppTheme.textSub)),
                                            TextSpan(
                                              text: "¥${NumberFormat('#,##0.00').format(paid / 100)}",
                                              style: TextStyle(
                                                  color: AppTheme.accent,
                                                  fontWeight: FontWeight.w700),
                                            ),
                                            TextSpan(text: L10n.instance.t('project_pending_pre'), style: TextStyle(color: AppTheme.textSub)),
                                            TextSpan(
                                              text: remaining <= 0
                                                  ? L10n.instance.t('projects_page_settled')
                                                  : "¥${NumberFormat('#,##0.00').format(remaining / 100)}",
                                              style: TextStyle(
                                                  color: remaining <= 0 ? AppTheme.accent : AppTheme.warn,
                                                  fontWeight: FontWeight.w700),
                                            ),
                                            TextSpan(text: L10n.instance.t('project_cost_pre'), style: TextStyle(color: AppTheme.textSub)),
                                            TextSpan(
                                              text: '¥${NumberFormat('#,##0.00').format((_costTotals[pr.id] ?? 0) / 100)}',
                                              style: TextStyle(
                                                  color: AppTheme.warn,
                                                  fontWeight: FontWeight.w700),
                                            ),
                                          ],
                                        ),
                                        style: const TextStyle(fontSize: 13),
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.visible,
                                      ),
                                    ),
                                  SizedBox(height: 6),
                                  LinearProgressIndicator(
                                    value: (pr.progress / 100).clamp(0.0, 1.0),
                                    minHeight: 4,
                                    backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                                    color: pr.progress >= 100 ? AppTheme.accent : AppTheme.primary,
                                    borderRadius: BorderRadius.circular(AppRadius.xxs),
                                  ),
                                  SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Text(L10n.instance.t('projects_progress_line', args: {'pr.progress': '${pr.progress}'}),
                                          style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
                                      const Spacer(),
                                      ..._deliverMark(pr),
                                    ],
                                  ),
                                ],
                              ),
                              isThreeLine: false,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.payments_outlined, size: 22),
                                      color: AppTheme.primary,
                                      tooltip: L10n.instance.t('project_record_payment'),
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () async {
                                        final ok = await showPaymentDialog(
                                          context,
                                          projectId: pr.id!,
                                          amountTotal: pr.amountTotal,
                                          paidTotal: paid,
                                        );
                                        if (ok) await _load();
                                      },
                                    ),
                                    _StatusBadge(status: pr.status),
                                  ],
                                ),
                                  ),
                                ),
                              ),
                            );
                        },
                      ),
          ),
        ],
      ),
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
