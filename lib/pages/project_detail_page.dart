import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../constants.dart';
import '../theme.dart';
import '../state/ticker.dart';
import '../widgets/payment_dialog.dart';
import '../widgets/show_payment_code.dart';
import 'quote_page.dart';

class ProjectDetailPage extends StatefulWidget {
  final Project project;
  final String customerName;
  const ProjectDetailPage({super.key, required this.project, required this.customerName});

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  late Project _project;
  List<Payment> _payments = [];
  double _paidTotal = 0;
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
    if (!mounted) return;
    setState(() {
      _payments = payments;
      _paidTotal = paid;
      _loading = false;
    });
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
        title: const Text('删除收款记录'),
        content: Text(
            '确定删除这笔 ¥${_fmt.format(p.amount)} 的收款记录吗？\n删除后项目已收金额会相应减少。'),
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
        title: const Text('删除项目'),
        content: const Text('将删除该项目及其全部收款记录，不可恢复。确定吗？'),
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
    if (ok == true) {
      await AppDb.instance.deleteProject(_project.id!);
      Ticker.ping();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = (_project.amountTotal - _paidTotal).clamp(0, double.infinity);
    final progress = _project.amountTotal <= 0 ? 0.0 : (_paidTotal / _project.amountTotal);
    return Scaffold(
      appBar: AppBar(
        title: Text(_project.title),
        actions: [
          IconButton(
            tooltip: '报价单',
            icon: const Icon(Icons.receipt_long_outlined),
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
          ? const Center(child: CircularProgressIndicator())
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
                                  const SizedBox(height: 6),
                                  Text('客户：${widget.customerName}', style: const TextStyle(color: AppTheme.textSub)),
                                ],
                              ),
                            ),
                            _StatusBadge(status: _project.status),
                          ],
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                          color: AppTheme.accent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _Amount(col: AppTheme.textSub, label: '约定总额', value: '¥${_fmt.format(_project.amountTotal)}'),
                            _Amount(col: AppTheme.accent, label: '已收', value: '¥${_fmt.format(_paidTotal)}'),
                            _Amount(col: AppTheme.warn, label: '待收', value: '¥${_fmt.format(remaining)}'),
                          ],
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: _advanceStatus,
                          icon: const Icon(Icons.arrow_forward),
                          label: Text('进入「${_nextLabel()}」'),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('收款记录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                      TextButton.icon(
                        onPressed: _collectPayment,
                        icon: const Icon(Icons.payments_outlined, size: 18),
                        label: const Text('收款'),
                      ),
                      TextButton.icon(onPressed: _addPayment, icon: const Icon(Icons.add, size: 18), label: const Text('登记收款')),
                    ],
                  ),
                ),
                if (_payments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('还没有收款记录', style: TextStyle(color: AppTheme.textSub))),
                  )
                else
                  ..._payments.map((p) => Card(
                        child: ListTile(
                          leading: Icon(Icons.account_balance_wallet_outlined, color: AppTheme.accent),
                          title: Text('¥${_fmt.format(p.amount)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${p.displayType} · ${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch(p.paidAt))}${p.note.isEmpty ? '' : ' · ${p.note}'}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textSub),
                            onPressed: () => _deletePayment(p),
                          ),
                        ),
                      )),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _deleteProject,
                  style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, side: const BorderSide(color: AppTheme.danger)),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除项目'),
                ),
              ],
            ),
    );
  }

  String _nextLabel() {
    switch (_project.status) {
      case ProjectStatus.accepted:
        return '制作中';
      case ProjectStatus.working:
        return '待收尾款';
      case ProjectStatus.awaiting:
        return '完结';
      case ProjectStatus.done:
        return '待收尾款（重新开启）';
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
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
