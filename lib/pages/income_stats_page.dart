import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../theme.dart';

/// 收入统计页（v1.10.0 新增）：
/// 近 12 个月收入柱状图、客户贡献排行、收款/待收构成。
/// 数据全部来自本机 SQLite，不涉及任何云端。
class IncomeStatsPage extends StatefulWidget {
  const IncomeStatsPage({super.key});

  @override
  State<IncomeStatsPage> createState() => _IncomeStatsPageState();
}

class _IncomeStatsPageState extends State<IncomeStatsPage> {
  bool _loading = true;
  List<Map<String, int>> _monthly = [];
  List<Map<String, Object?>> _contrib = [];
  Map<String, int> _paidVsPending = {'paid': 0, 'pending': 0};
  final _fmt = NumberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppDb.instance;
    final monthly = await db.monthlyIncomeLast12();
    final contrib = await db.customerContribution();
    final summary = await db.paidVsPendingSummary();
    if (!mounted) return;
    setState(() {
      _monthly = monthly;
      _contrib = contrib;
      _paidVsPending = summary;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收入统计')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  _buildCompositionCard(),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
                    child: Text('近 12 个月收入',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textMain)),
                  ),
                  _MonthlyBarChart(data: _monthly),
                  const SizedBox(height: 12),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
                    child: Text('客户贡献排行',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textMain)),
                  ),
                  _buildContributionCard(),
                ],
              ),
            ),
    );
  }

  // 收款 / 待收构成
  Widget _buildCompositionCard() {
    final paid = _paidVsPending['paid'] ?? 0;
    final pending = _paidVsPending['pending'] ?? 0;
    final total = paid + pending;
    final paidRatio = total <= 0 ? 0.0 : paid / total;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('收款 / 待收构成',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                _Legend(color: AppTheme.accent, label: '已收 ¥${_fmt.format(paid / 100)}'),
                const SizedBox(width: 16),
                _Legend(color: AppTheme.warn, label: '待收 ¥${_fmt.format(pending / 100)}'),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: paidRatio,
                minHeight: 10,
                backgroundColor: AppTheme.warn.withValues(alpha: 0.25),
                color: AppTheme.accent,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '已收占比 ${(paidRatio * 100).toStringAsFixed(1)}%',
              style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContributionCard() {
    if (_contrib.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text('还没有收款记录，暂无客户贡献数据',
                style: TextStyle(color: AppTheme.textSub)),
          ),
        ),
      );
    }
    final maxTotal =
        (_contrib.first['total'] as num?)?.toInt() ?? 1;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (int i = 0; i < _contrib.length; i++)
            _ContribRow(
              rank: i + 1,
              name: (_contrib[i]['customer_name'] as String?) ?? '',
              total: (_contrib[i]['total'] as num?)?.toInt() ?? 0,
              ratio: maxTotal <= 0
                  ? 0.0
                  : (((_contrib[i]['total'] as num?)?.toInt() ?? 0) /
                      maxTotal),
            ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

class _ContribRow extends StatelessWidget {
  final int rank;
  final String name;
  final int total;
  final double ratio;
  const _ContribRow({
    required this.rank,
    required this.name,
    required this.total,
    required this.ratio,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: rank <= 3
                  ? AppTheme.primary.withValues(alpha: 0.12)
                  : AppTheme.textSub.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text('$rank',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: rank <= 3 ? AppTheme.primary : AppTheme.textSub)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                    color: AppTheme.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text('¥${fmt.format(total / 100)}',
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textMain,
                  fontSize: 14)),
        ],
      ),
    );
  }
}

/// 近 12 个月收入柱状图（自绘，不引入图表库）
class _MonthlyBarChart extends StatelessWidget {
  final List<Map<String, int>> data;
  const _MonthlyBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    final maxV = data.fold<int>(
        0, (m, e) => (e['amount'] ?? 0) > m ? (e['amount'] ?? 0) : m);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 210,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final e in data)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if ((e['amount'] ?? 0) > 0)
                              Text(
                                fmt.format((e['amount'] ?? 0) / 100),
                                style: const TextStyle(
                                    fontSize: 9, color: AppTheme.textSub),
                              ),
                            const SizedBox(height: 3),
                            Container(
                              height: maxV <= 0
                                  ? 2
                                  : 4 +
                                      (140 *
                                          ((e['amount'] ?? 0) / maxV)
                                              .clamp(0.0, 1.0)),
                              width: 18,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF4A5AF0),
                                    Color(0xFF7C5CF0),
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4)),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final e in data)
                    Expanded(
                      child: Text(
                        '${e['month']}月',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 10, color: AppTheme.textSub),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
