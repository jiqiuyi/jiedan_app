import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../constants.dart';
import '../theme.dart';
import '../state/ticker.dart';
import '../widgets/show_payment_code.dart';
import 'income_history_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _fmt = NumberFormat('#,##0.00');
  int _monthIncome = 0;
  int _projectCount = 0;
  int _customerCount = 0;
  int _awaitingAmount = 0;
  int _doneCount = 0;
  List<Project> _recent = [];
  List<PendingCollection> _pendings = [];
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _refesh();
    _sub = Ticker.counterStream.listen((_) => _refesh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refesh() async {
    final now = DateTime.now();
    final db = AppDb.instance;
    final month = await db.monthPaidTotal(now.year, now.month);
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
      _projectCount = projects.length;
      _customerCount = customers.length;
      _awaitingAmount = awaiting;
      _doneCount = projects.where((e) => e.status == ProjectStatus.done).length;
      _recent = projects.take(5).toList();
      _pendings = pendings;
    });
  }

  /// 看板收款入口：选择项目 → 选择渠道 → 展示收款码 → 手动确认到账
  Future<void> _collectPayment() async {
    final db = AppDb.instance;
    final projects = await db.getProjects();
    if (!mounted) return;
    if (projects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有项目，请先到「项目」页新建')),
      );
      return;
    }
    final selected = await showModalBottomSheet<Project>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('选择要收款的项目',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
        title: const Text('结清待收尾款'),
        content: Text('确认已收到「${p.title}」的 ¥${_fmt.format(p.amount / 100)} 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认结清'),
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
        title: const Text('删除待收记录'),
        content: Text('确定删除「${p.title}」的待收记录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
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
      appBar: AppBar(title: const Text('看板')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: _collectPayment,
        icon: const Icon(Icons.payments_outlined),
        label: const Text('收款'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const IncomeHistoryPage()),
            ),
            child: _IncomeCard(amount: _monthIncome, fmt: _fmt),
          ),
          Row(
            children: [
              _StatCard(
                label: '进行中项目',
                value: '${_projectCount - _doneCount}',
                color: AppTheme.primary,
              ),
              _StatCard(
                label: '待收尾款',
                value: '¥${_fmt.format(_awaitingAmount / 100)}',
                color: AppTheme.warn,
              ),
            ],
          ),
          Row(
            children: [
              _StatCard(
                label: '客户数',
                value: '$_customerCount',
                color: AppTheme.accent,
              ),
              _StatCard(
                label: '项目总数',
                value: '$_projectCount',
                color: AppTheme.textSub,
              ),
            ],
          ),
          if (_pendings.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text('待收尾款', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textMain)),
            ),
            ..._pendings.map((p) => _PendingCard(
                  item: p,
                  fmt: _fmt,
                  onSettle: () => _settlePending(p),
                  onDelete: () => _deletePending(p),
                )),
          ],
          const SizedBox(height: 10),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text('最近项目', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textMain)),
          ),
          if (_recent.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('还没有项目，去「项目」页建一个吧', style: TextStyle(color: AppTheme.textSub))),
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
  final NumberFormat fmt;
  const _IncomeCard({required this.amount, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final month = DateFormat('M月').format(DateTime.now());
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4A5AF0), Color(0xFF7C5CF0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本月收入', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          const SizedBox(height: 8),
          Text('¥${fmt.format(amount / 100)}',
              style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Text('本月新增款项合计 · $month · 点击查看历史记录',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
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
  const _RecentCard({required this.project});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    return Card(
      child: ListTile(
        title: Text(project.title, style: const TextStyle(fontWeight: FontWeight.w600)),
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
        borderRadius: BorderRadius.circular(20),
      ),
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

/// 看板待收尾款列表项（v1.10.0）
class _PendingCard extends StatelessWidget {
  final PendingCollection item;
  final NumberFormat fmt;
  final VoidCallback onSettle;
  final VoidCallback onDelete;
  const _PendingCard({
    required this.item,
    required this.fmt,
    required this.onSettle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dueText = item.dueDate > 0
        ? '到期 ${DateFormat('MM-dd').format(DateTime.fromMillisecondsSinceEpoch(item.dueDate))}'
        : '未设到期日';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.schedule, color: AppTheme.warn),
        title: Text(item.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(dueText,
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('¥${fmt.format(item.amount / 100)}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.warn)),
            IconButton(
              tooltip: '标记已收款',
              icon: const Icon(Icons.check_circle_outline,
                  size: 20, color: AppTheme.accent),
              onPressed: onSettle,
            ),
            IconButton(
              tooltip: '删除',
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
