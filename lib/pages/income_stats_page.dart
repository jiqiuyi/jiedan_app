import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../theme.dart';

/// 收入统计页（v1.10.0 新增）：
/// 近 12 个月收入柱状图、客户贡献排行、应收款项/报价与收入口径汇总。
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
  // 三个统计口径各自独立保存（单位均为分），避免平铺在一个 map 里互相污染：
  int _quoteTotal = 0; // 口径一：全部报价总金额
  int _received = 0; // 口径二：实际已收款
  int _receivable = 0; // 口径三：尚未收回应收欠款
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
    // 报价总额需要读取全量报价记录后自行求和，避免在 DB 层新增聚合 SQL。
    final quotes = await db.getQuotes();
    if (!mounted) return;
    setState(() {
      _monthly = monthly;
      _contrib = contrib;
      // 三种口径分开计算，互不影响：
      _quoteTotal = calcTotalQuoteAmount(quotes);
      _received = calcReceivedAmount(summary);
      _receivable = calcReceivableAmount(summary);
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
                  _buildReceivableCard(),
                  const SizedBox(height: 6),
                  _buildAmountOverviewCard(),
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

  // 应收欠款独立高亮卡片：自由职业最关心「还有多少钱没收回来」，单独成块突出展示。
  Widget _buildReceivableCard() {
    final cleared = _receivable <= 0;
    final receivableText = _fmt.format(_receivable / 100);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: cleared
            ? const LinearGradient(
                colors: [Color(0xFF27AE60), Color(0xFF2EBD85)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : const LinearGradient(
                colors: [Color(0xFFE67E22), Color(0xFFF39C12)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                cleared ? Icons.check_circle_outline : Icons.notifications_active_outlined,
                size: 18,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                cleared ? '应收款项 · 已全部结清' : '应收欠款 · 待追回',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9), fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '¥${cleared ? '0.00' : receivableText}',
            style: const TextStyle(
                color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          // 业务口径说明：应收欠款 = 待收余额（部分收款或全款未收时的未回款金额）
          Text(
            cleared
                ? '无未回款，所有收款均已结清'
                : '共 ¥$receivableText 尚未收回，请及时跟进催收',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12),
          ),
        ],
      ),
    );
  }

  // 报价总金额 / 实际已收款 口径汇总卡片：区分「全部报价」「实际到手收入」两类业务口径。
  Widget _buildAmountOverviewCard() {
    final quoteTotal = _quoteTotal < 0 ? 0 : _quoteTotal;
    final received = _received < 0 ? 0 : _received;
    final receivedRatio =
        quoteTotal <= 0 ? 0.0 : (received / quoteTotal).clamp(0.0, 1.0);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('报价与收入口径',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                // 口径一：全部报价总金额（含税一口价 / 详细报价合计）
                _Legend(
                    color: AppTheme.primary,
                    label: '全部报价 ¥${_fmt.format(quoteTotal / 100)}'),
                const SizedBox(width: 16),
                // 口径二：累计实际到账收入
                _Legend(
                    color: AppTheme.accent,
                    label: '已收入 ¥${_fmt.format(received / 100)}'),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: receivedRatio,
                minHeight: 10,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
                color: AppTheme.accent,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              quoteTotal <= 0
                  ? '暂无报价数据，先去「报价」页创建报价单'
                  : '已收入占报价总额 ${(receivedRatio * 100).toStringAsFixed(1)}%',
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

// ---- 业务统计口径计算（纯函数，便于单元测试与复用）----
// 三个口径互相独立：报价总额、实际已收、应收欠款，单位均为「分」。
// 所有入参负数一律按 0 处理，防止脏数据扭曲统计结果。

// 口径一：全部报价总金额（分）。遍历全部报价记录求和，负数视为非法值按 0 计。
int calcTotalQuoteAmount(List<Quote> quotes) {
  var total = 0;
  for (final q in quotes) {
    total += q.total < 0 ? 0 : q.total;
  }
  return total;
}

// 口径二：实际已收款（分）。负数兜底置 0。
int calcReceivedAmount(Map<String, int> summary) {
  final paid = summary['paid'] ?? 0;
  return paid < 0 ? 0 : paid;
}

// 口径三：应收欠款（分）。按业务状态区分：
//  - 待收余额为 0：全款已结清，无应收欠款；
//  - 待收余额 > 0：部分收款或全款未收，应收欠款即为待收余额；
//  - 数值非法（<0）一律兜底为 0。
int calcReceivableAmount(Map<String, int> summary) {
  final pending = summary['pending'] ?? 0;
  if (pending <= 0) return 0;
  return pending;
}
