import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../constants.dart';
import '../theme.dart';
import '../state/ticker.dart';
import 'income_history_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _fmt = NumberFormat('#,##0.00');
  double _monthIncome = 0;
  int _projectCount = 0;
  int _customerCount = 0;
  double _awaitingAmount = 0;
  List<Project> _recent = [];
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
    double awaiting = 0;
    for (final pr in projects) {
      if (pr.status == ProjectStatus.awaiting) {
        final paid = await db.projectPaidTotal(pr.id!);
        awaiting += (pr.amountTotal - paid).clamp(0, double.infinity);
      }
    }
    if (!mounted) return;
    setState(() {
      _monthIncome = month;
      _projectCount = projects.length;
      _customerCount = customers.length;
      _awaitingAmount = awaiting;
      _recent = projects.take(5).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('看板')),
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
                value: '${_projectCount - _doneCount()}',
                color: AppTheme.primary,
              ),
              _StatCard(
                label: '待收尾款',
                value: '¥${_fmt.format(_awaitingAmount)}',
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

  int _doneCount() => _recent.where((e) => e.status == ProjectStatus.done).length;
}

class _IncomeCard extends StatelessWidget {
  final double amount;
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
          Text('¥${fmt.format(amount)}',
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
        subtitle: Text('${project.status.label} · ¥${fmt.format(project.amountTotal)}',
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
