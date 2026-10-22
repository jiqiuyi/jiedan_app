import 'dart:async';
import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../constants.dart';
import '../api_client.dart';
import '../theme.dart';
import '../services/error_reporter.dart';
import '../state/ticker.dart';
import '../widgets/show_payment_code.dart';
import 'income_history_page.dart';
import '../widgets/app_ui.dart';

class DashboardPage extends StatefulWidget {
const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _fmt = NumberFormat('#,##0.00');
  int _monthIncome = 0;
  int _monthCost = 0; // 本月成本（当月新增 project_costs 合计）
  int _monthProfit = 0; // 本月利润 = 本月收入 − 本月成本
  int _allCostTotal = 0; // 累计成本（全部 project_costs 合计）
  int _projectCount = 0;
  int _customerCount = 0;
  int _awaitingAmount = 0;
  int _doneCount = 0;
  List<Project> _recent = [];
  List<PendingCollection> _pendings = [];
  StreamSubscription<int>? _sub;
  Map<String, dynamic> _announce = {'title': '', 'content': '', 'active': false};
  bool _announceHidden = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _refesh();
    _sub = Ticker.counterStream.listen((_) => _refesh());
    _loadAnnounce();
  }

  /// 拉取 App 公告（后台配置；失败静默，不打扰使用）
  Future<void> _loadAnnounce() async {
    final a = await ApiClient.instance.fetchAnnouncement();
    if (!mounted) return;
    setState(() => _announce = a);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refesh() async {
    // 看板为启动 / 登录成功后的首页：三星等设备 SQLite 偶发异常若冒泡会触发
    // 全局兜底弹窗「操作未能完成，请稍后重试」。这里一律降级为留日志静默，
    // 保留当前已展示数据不刷新（下个 Ticker 周期仍会重试）。
    try {
      final now = DateTime.now();
      final db = AppDb.instance;
      final month = await db.monthPaidTotal(now.year, now.month);
      final monthCost = await db.monthCostTotal(now.year, now.month);
      final allCost = await db.allCostTotal();
      final projects = await db.getProjects();
      final customers = await db.getCustomers();
      final pendings = await db.getPendingCollections(onlyPending: true);
      // N+1 修复：一次批量查询所有项目已收总额，避免逐项目查询
      final paidTotals = await db.projectPaidTotals();
      int awaiting = 0;
      for (final pr in projects) {
        if (pr.status == ProjectStatus.awaiting) {
          final paid = paidTotals[pr.id] ?? 0;
          final remain = pr.amountTotal - paid;
          if (remain > 0) awaiting += remain;
        }
      }
      if (!mounted) return;
      setState(() {
        _monthIncome = month;
        _monthCost = monthCost;
        _monthProfit = month - monthCost;
        _allCostTotal = allCost;
        _projectCount = projects.length;
        _customerCount = customers.length;
        _awaitingAmount = awaiting;
        _doneCount = projects.where((e) => e.status == ProjectStatus.done).length;
        _recent = projects.take(5).toList();
        _pendings = pendings;
        _loadFailed = false;
      });
    } catch (e, st) {
      ErrorReporter.instance.logError('dashboard_refesh', e, st);
      // 三态兜底：DB 持续失败时置错误态，页面顶部显示「加载失败 + 重试」横幅，
      // 避免用户以为一直加载中无任何反馈（旧数据仍保留展示）。
      if (mounted) {
        setState(() {
          _loadFailed = true;
        });
      }
    }
  }

  /// 看板收款入口：选择项目 → 选择渠道 → 展示收款码 → 手动确认到账
  Future<void> _collectPayment() async {
    final db = AppDb.instance;
    final projects = await db.getProjects();
    if (!mounted) return;
    if (projects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('dashboard_no_project'))),
      );
      return;
    }
    final selected = await showAppSheet<Project>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(14),
              child: AppSheetHeader(title: L10n.instance.t('dashboard_choose_project')),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: projects
                    .map((pr) => ListTile(
                          title: Text(pr.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(pr.status.label,
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.textSub)),
                          onTap: () => Navigator.pop(ctx, pr),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final paid = await db.projectPaidTotal(selected.id!);
    if (!mounted) return;
    final ok = await showProjectCollectSheet(
      context,
      projectId: selected.id!,
      projectTitle: selected.title,
      amountTotal: selected.amountTotal,
      paidTotal: paid,
    );
    if (ok) _refesh();
  }

  /// 看板待收尾款：结清（标记已收款）
  Future<void> _settlePending(PendingCollection p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('dashboard_settle_pending')),
        content: Text(L10n.instance.t('dashboard_confirm_received_confirm', args: {'p.title': p.title, '_fmt.format(p.amount / 100)': _fmt.format(p.amount / 100)})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('dashboard_confirm_settle')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.settlePending(p.id!);
    _refesh();
  }

  /// 看板待收尾款：删除记录
  Future<void> _deletePending(PendingCollection p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('dashboard_delete_record')),
        content: Text(L10n.instance.t('dashboard_delete_pending_confirm', args: {'p.title': p.title})),
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
    await AppDb.instance.deletePendingCollection(p.id!);
    _refesh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('home_tab_home'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: _collectPayment,
        icon: Icon(Icons.payments_outlined),
        label: Text(L10n.instance.t('common_collect')),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (_loadFailed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Material(
                color: AppTheme.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: AppTheme.danger),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(L10n.instance.t('common_load_failed_retry'),
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.danger)),
                      ),
                      TextButton(
                        onPressed: () => _refesh(),
                        child: Text(L10n.instance.t('common_retry')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_announceHidden &&
              _announce['active'] == true &&
              (_announce['title'] as String? ?? '').isNotEmpty)
            _AnnounceCard(
              title: (_announce['title'] as String? ?? '').toString(),
              content: (_announce['content'] as String? ?? '').toString(),
              onClose: () => setState(() => _announceHidden = true),
            ),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const IncomeHistoryPage()),
            ),
            child: _IncomeCard(
              amount: _monthIncome,
              monthCost: _monthCost,
              monthProfit: _monthProfit,
              allCost: _allCostTotal,
              fmt: _fmt,
            ),
          ),
          Row(
            children: [
              _StatCard(
                label: L10n.instance.t('dashboard_active_projects'),
                value: '${_projectCount - _doneCount}',
                color: AppTheme.primary,
              ),
              _StatCard(
                label: L10n.instance.t('dashboard_pending_final'),
                value: '¥${_fmt.format(_awaitingAmount / 100)}',
                color: AppTheme.warn,
              ),
            ],
          ),
          Row(
            children: [
              _StatCard(
                label: L10n.instance.t('dashboard_customer_count'),
                value: '$_customerCount',
                color: AppTheme.accent,
              ),
              _StatCard(
                label: L10n.instance.t('dashboard_project_total'),
                value: '$_projectCount',
                color: AppTheme.textSub,
              ),
            ],
          ),
          if (_pendings.isNotEmpty) ...[
            SizedBox(height: 10),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(L10n.instance.t('dashboard_pending_final'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textMain)),
            ),
            ..._pendings.map((p) => _PendingCard(
                  item: p,
                  fmt: _fmt,
                  onSettle: () => _settlePending(p),
                  onDelete: () => _deletePending(p),
                )),
          ],
          SizedBox(height: 10),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text(L10n.instance.t('dashboard_recent'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textMain)),
          ),
          if (_recent.isEmpty)
            AppEmpty(
              icon: Icons.folder_open_outlined,
              title: L10n.instance.t('dashboard_no_project2'),
            )
          else
            ..._recent.map((pr) => _RecentCard(project: pr)),
        ],
      ),
    );
  }
}

class _IncomeCard extends StatelessWidget {
  final int amount; // 分
  final int monthCost; // 本月成本（分）
  final int monthProfit; // 本月利润（分）
  final int allCost; // 累计成本（分）
  final NumberFormat fmt;
const _IncomeCard({
    required this.amount,
    required this.monthCost,
    required this.monthProfit,
    required this.allCost,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    final month = DateFormat(L10n.instance.t('i18n_039')).format(DateTime.now());
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4A5AF0), Color(0xFF7C5CF0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(L10n.instance.t('dashboard_month_income'), style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          SizedBox(height: 8),
          Text('¥${fmt.format(amount / 100)}',
              style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
          SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _MiniStat(label: L10n.instance.t('dashboard_month_cost'), value: '¥${fmt.format(monthCost / 100)}')),
              SizedBox(width: 8),
              Expanded(child: _MiniStat(label: L10n.instance.t('dashboard_month_profit'), value: '¥${fmt.format(monthProfit / 100)}')),
              SizedBox(width: 8),
              Expanded(child: _MiniStat(label: L10n.instance.t('dashboard_total_cost'), value: '¥${fmt.format(allCost / 100)}')),
            ],
          ),
          SizedBox(height: 14),
          Text(L10n.instance.t('dashboard_month_new', args: {'month':month}),
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sheet),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11)),
          SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
const _StatCard({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(height: 10),
              Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textSub)),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  final Project project;
const   _RecentCard({required this.project});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    return Card(
      child: ListTile(
        title: Text(project.title, style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${project.status.label} · ¥${fmt.format(project.amountTotal / 100)}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _StatusBadge(status: project.status),
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
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sheet),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          SizedBox(width: 4),
          Text(status.label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 看板待收尾款列表项（v1.10.0）
class _PendingCard extends StatelessWidget {
  final PendingCollection item;
  final NumberFormat fmt;
  final VoidCallback onSettle;
  final VoidCallback onDelete;
const   _PendingCard({
    required this.item,
    required this.fmt,
    required this.onSettle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dueText = item.dueDate > 0
        ? L10n.instance.t('dashboard_due', args: {'v0': DateFormat('MM-dd').format(DateTime.fromMillisecondsSinceEpoch(item.dueDate))})
        : L10n.instance.t('i18n_445');
    return Card(
      child: ListTile(
        leading: Icon(Icons.schedule, color: AppTheme.warn),
        title: Text(item.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(dueText,
            style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('¥${fmt.format(item.amount / 100)}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.warn)),
            IconButton(
              tooltip: L10n.instance.t('dashboard_mark_paid'),
              icon: const Icon(Icons.check_circle_outline,
                  size: 20, color: AppTheme.accent),
              onPressed: onSettle,
            ),
            IconButton(
              tooltip: L10n.instance.t('common_delete'),
              icon: const Icon(Icons.delete_outline,
                  size: 20, color: AppTheme.textSub),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 看板顶部公告横幅（后台「公告管理」→ App 公告）
class _AnnounceCard extends StatelessWidget {
  final String title;
  final String content;
  final VoidCallback onClose;
const _AnnounceCard({
    required this.title,
    required this.content,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Color(0xFFEEF2FF),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.campaign_outlined,
                  size: 18, color: AppTheme.primary),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textMain)),
                  if (content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(content,
                          style: const TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: AppTheme.textSub)),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: L10n.instance.t('common_close'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16, color: AppTheme.textSub),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
