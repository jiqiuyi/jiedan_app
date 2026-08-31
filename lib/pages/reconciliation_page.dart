import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../theme.dart';

/// 对账汇总页（v1.10.0 新增）：
/// 本地收款流水对账：每个项目展示 约定总额 / 已收 / 待收。
/// 数据来自本机 SQLite reconciliationSummary()，不涉及云端。
class ReconciliationPage extends StatefulWidget {
  const ReconciliationPage({super.key});

  @override
  State<ReconciliationPage> createState() => _ReconciliationPageState();
}

class _ReconciliationPageState extends State<ReconciliationPage> {
  bool _loading = true;
  List<Map<String, Object?>> _rows = [];
  final _fmt = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await AppDb.instance.reconciliationSummary();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  int _v(Object? v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final totalAgreed = _rows.fold<int>(0, (s, r) => s + _v(r['amount_total']));
    final totalPaid = _rows.fold<int>(0, (s, r) => s + _v(r['paid_total']));
    final totalPending = _rows.fold<int>(0, (s, r) => s + _v(r['pending_total']));
    final cleared = _rows
        .where((r) => _v(r['pending_total']) <= 0)
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('对账汇总')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  _SummaryCard(
                    totalAgreed: totalAgreed,
                    totalPaid: totalPaid,
                    totalPending: totalPending,
                    cleared: cleared,
                    all: _rows.length,
                  ),
                  const SizedBox(height: 6),
                  if (_rows.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text('还没有项目收款数据',
                              style: TextStyle(color: AppTheme.textSub)),
                        ),
                      ),
                    )
                  else
                    Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          for (int i = 0; i < _rows.length; i++)
                            _buildRow(_rows[i], i),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildRow(Map<String, Object?> r, int index) {
    final agreed = _v(r['amount_total']);
    final paid = _v(r['paid_total']);
    final pending = _v(r['pending_total']);
    final ratio = agreed <= 0 ? 0.0 : (paid / agreed).clamp(0.0, 1.0);
    final title = (r['project_title'] as String?)?.trim() ?? '';
    final customer = (r['customer_name'] as String?)?.trim() ?? '';
    return Column(
      children: [
        if (index > 0) const Divider(height: 1, indent: 14, endIndent: 14),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? '（未命名项目）' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  if (pending <= 0)
                    const _Tag(text: '已结清', color: AppTheme.accent)
                  else
                    _Tag(text: '待收中', color: AppTheme.warn),
                ],
              ),
              if (customer.isNotEmpty)
                Text(customer,
                    style: const TextStyle(
                        color: AppTheme.textSub, fontSize: 12)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _Item(
                        label: '约定',
                        value: '¥${_fmt.format(agreed / 100)}',
                        color: AppTheme.textMain),
                  ),
                  Expanded(
                    child: _Item(
                        label: '已收',
                        value: '¥${_fmt.format(paid / 100)}',
                        color: AppTheme.accent),
                  ),
                  Expanded(
                    child: _Item(
                        label: '待收',
                        value: '¥${_fmt.format(pending / 100)}',
                        color: AppTheme.warn),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text('收款进度 ${(ratio * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSub)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _Item extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Item({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int totalAgreed;
  final int totalPaid;
  final int totalPending;
  final int cleared;
  final int all;
  const _SummaryCard({
    required this.totalAgreed,
    required this.totalPaid,
    required this.totalPending,
    required this.cleared,
    required this.all,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('汇总',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SumItem(
                      label: '约定总额',
                      value: '¥${fmt.format(totalAgreed / 100)}'),
                ),
                Expanded(
                  child: _SumItem(
                      label: '累计已收',
                      value: '¥${fmt.format(totalPaid / 100)}',
                      color: AppTheme.accent),
                ),
                Expanded(
                  child: _SumItem(
                      label: '待收总额',
                      value: '¥${fmt.format(totalPending / 100)}',
                      color: AppTheme.warn),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('共 $all 个项目，已结清 $cleared 个',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSub)),
          ],
        ),
      ),
    );
  }
}

class _SumItem extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SumItem({required this.label, required this.value, this.color = AppTheme.textMain});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}
