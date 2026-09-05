import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../theme.dart';
import 'paywall_page.dart';

/// 统计看板（v1.10.0 新增，v1.22.0 增强）：
/// 收入/应收统计支持时间范围筛选（本月/上月/近12个月/自定义起止日期）与月度对比、
/// 分类汇总（按客户 / 按报价类型 / 按项目阶段）。
/// 统计口径自动排除草稿(draft)、作废(voided) 报价与报价模板(is_template=1)。
/// 数据全部来自本机 SQLite，不涉及任何云端。
class IncomeStatsPage extends StatefulWidget {
  const IncomeStatsPage({super.key});

  @override
  State<IncomeStatsPage> createState() => _IncomeStatsPageState();
}

/// 时间范围模式
enum _RangeMode {
  month, // 本月
  lastMonth, // 上月
  last12, // 近12个月
  custom, // 自定义起止日期
}

/// 分类汇总维度
enum _GroupMode { customer, quoteType, projectStatus }

class _IncomeStatsPageState extends State<IncomeStatsPage> {
  bool _loading = true;
  _RangeMode _mode = _RangeMode.last12;
  _GroupMode _group = _GroupMode.customer;
  final _fmt = NumberFormat('#,##0.00');

  // 各统计口径（单位均为分，展示时统一 /100）：
  int _paidTotal = 0; // 范围内实际已收款
  int _quoteTotal = 0; // 范围内有效报价总额（排除草稿/作废）
  int _receivable = 0; // 应收欠款（当前存量，不对时间过滤）
  int _lastMonthIncome = 0; // 上月收入（用于月度对比）
  String _rangeTitle = '近12个月';

  // 自定义起止日期（当天）：
  DateTime _rStart = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _rEnd = DateTime.now();

  List<Map<String, int>> _monthly = [];
  List<Map<String, Object?>> _contrib = [];
  List<Map<String, Object?>> _byType = [];
  List<Map<String, Object?>> _byStatus = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 当前模式的时间范围 [startMs, endMs) 与范围标题
  (int, int) _rangeOf() {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.month:
        final s = DateTime(now.year, now.month, 1);
        return (s.millisecondsSinceEpoch, now.millisecondsSinceEpoch + 1);
      case _RangeMode.lastMonth:
        final s = DateTime(now.year, now.month - 1, 1);
        final e = DateTime(now.year, now.month, 1);
        return (s.millisecondsSinceEpoch, e.millisecondsSinceEpoch);
      case _RangeMode.last12:
        final s = DateTime(now.year, now.month - 11, 1);
        return (s.millisecondsSinceEpoch, now.millisecondsSinceEpoch + 1);
      case _RangeMode.custom:
        final e = DateTime(_rEnd.year, _rEnd.month, _rEnd.day + 1);
        return (_rStart.millisecondsSinceEpoch, e.millisecondsSinceEpoch);
    }
  }

  Future<void> _load() async {
    final db = AppDb.instance;
    final (startMs, endMs) = _rangeOf();
    final now = DateTime.now();
    _rangeTitle = _titleOf();
    // 并行取数：全部本地 SQLite，一次刷新完成
    final summary = await db.paidVsPendingSummary(); // 应收欠款（存量）
    final paid = await db.paidTotalInRange(startMs, endMs);
    final quoteTotal = await db.quotesTotalInRange(startMs: startMs, endMs: endMs);
    final lastMonth = await db.monthPaidTotal(
        now.month == 1 ? now.year - 1 : now.year, now.month == 1 ? 12 : now.month - 1);
    final monthly = await db.monthlyIncomeLast12();
    final contrib = await db.customerContributionInRange(startMs, endMs);
    final byType = await db.quotesByTypeInRange(startMs: startMs, endMs: endMs);
    final byStatus = await db.incomeByProjectStatus(startMs, endMs);
    if (!mounted) return;
    setState(() {
      _receivable = calcReceivableAmount(summary);
      _paidTotal = paid < 0 ? 0 : paid;
      _quoteTotal = quoteTotal < 0 ? 0 : quoteTotal;
      _lastMonthIncome = lastMonth;
      _monthly = monthly;
      _contrib = contrib;
      _byType = byType;
      _byStatus = byStatus;
      _loading = false;
    });
  }

  String _titleOf() {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.month:
        return '${now.year}年${now.month}月';
      case _RangeMode.lastMonth:
        final m = now.month == 1 ? 12 : now.month - 1;
        final y = now.month == 1 ? now.year - 1 : now.year;
        return '$y年$m月';
      case _RangeMode.last12:
        return '近12个月';
      case _RangeMode.custom:
        final f = NumberFormat('yyyy-MM-dd');
        return '${f.format(_rStart)} 至 ${f.format(_rEnd)}';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 第15批：统计·高级分析（自定义区间/月度对比/分类汇总）加 VIP 门禁，
    // 不隐藏入口，免费用户进入即见升级引导。
    if (!AppState.instance.isPro) {
      return _vipGate(
        context,
        appBarTitle: '统计看板',
        feature: '统计·高级分析',
        desc: '自定义日期区间、月度对比与分类汇总为专业版专属权益。',
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('统计看板')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  _buildRangeSelector(),
                  const SizedBox(height: 6),
                  _buildReceivableCard(),
                  const SizedBox(height: 6),
                  _buildRangeSummaryCard(),
                  if (_mode == _RangeMode.last12) ...[
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
                  ],
                  const SizedBox(height: 6),
                  _buildGroupSummary(),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 12, 18, 4),
                    child: Text(
                      '口径说明：统计默认排除「草稿」「作废」状态的报价及报价模板；'
                      '应收欠款为当前未回款存量，不随时间范围过滤。',
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.textSub),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // 时间范围筛选条：本月 / 上月 / 近12个月 / 自定义
  Widget _buildRangeSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (m, label) in [
            (_RangeMode.month, '本月'),
            (_RangeMode.lastMonth, '上月'),
            (_RangeMode.last12, '近12个月'),
            (_RangeMode.custom, '自定义'),
          ])
            ChoiceChip(
              label: Text(label),
              selected: _mode == m,
              onSelected: (_) {
                if (_mode == m) return;
                setState(() => _mode = m);
                _load();
              },
              visualDensity: VisualDensity.compact,
            ),
          if (_mode == _RangeMode.custom)
            TextButton.icon(
              onPressed: _pickCustomRange,
              icon: const Icon(Icons.date_range, size: 16),
              label: Text(_titleOf(),
                  style: const TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10, 1),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _rStart.isBefore(_rEnd) ? _rStart : _rEnd,
        end: _rEnd,
      ),
      helpText: '选择统计起止日期',
      saveText: '确定',
    );
    if (range == null || !mounted) return;
    setState(() {
      _rStart = DateTime(range.start.year, range.start.month, range.start.day);
      _rEnd = DateTime(range.end.year, range.end.month, range.end.day);
    });
    _load();
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
                cleared
                    ? Icons.check_circle_outline
                    : Icons.notifications_active_outlined,
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

  // 范围摘要卡：范围内实际收入 / 有效报价总额 + 与上月对比。
  Widget _buildRangeSummaryCard() {
    final delta = _paidTotal - _lastMonthIncome;
    final deltaRatio = _lastMonthIncome <= 0
        ? 0.0
        : (delta / _lastMonthIncome).clamp(-1.0, 1.0);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$_rangeTitle 统计',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    color: AppTheme.accent,
                    label: '$_rangeTitle 已收入',
                    value: '¥${_fmt.format(_paidTotal / 100)}',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Metric(
                    color: AppTheme.primary,
                    label: '$_rangeTitle 有效报价',
                    value: '¥${_fmt.format(_quoteTotal / 100)}',
                  ),
                ),
              ],
            ),
            if (_mode == _RangeMode.month ||
                _mode == _RangeMode.lastMonth) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    delta >= 0
                        ? Icons.trending_up
                        : Icons.trending_down,
                    size: 16,
                    color: delta >= 0
                        ? const Color(0xFF27AE60)
                        : const Color(0xFFE74C3C),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _mode == _RangeMode.month
                        ? '较上月 ${delta >= 0 ? '+' : ''}'
                            '${_fmt.format(delta / 100)}'
                            '（${(deltaRatio * 100).toStringAsFixed(1)}%）'
                        : '上月收入较本月 ${delta >= 0 ? '+' : ''}'
                            '${_fmt.format(delta / 100)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: delta >= 0
                            ? const Color(0xFF27AE60)
                            : const Color(0xFFE74C3C),
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // 分类汇总：维度切换 + 列表。
  Widget _buildGroupSummary() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text('分类汇总',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMain)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            children: [
              for (final (g, label) in [
                (_GroupMode.customer, '按客户'),
                (_GroupMode.quoteType, '按报价类型'),
                (_GroupMode.projectStatus, '按项目阶段'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _group == g,
                  onSelected: (_) => setState(() => _group = g),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        _buildGroupList(),
      ],
    );
  }

  Widget _buildGroupList() {
    switch (_group) {
      case _GroupMode.customer:
        return _buildRankList(
          rows: _contrib,
          emptyText: '所选时间范围内还没有收款记录',
        );
      case _GroupMode.quoteType:
        final rows = [
          for (final e in _byType)
            {
              'name': ((e['type'] as String?) == 'simple' ? '简单报价' : '详细报价'),
              'total': (e['total'] as num?)?.toInt() ?? 0,
            },
        ];
        return _buildRankList(
          rows: rows,
          emptyText: '所选时间范围内还没有有效报价',
        );
      case _GroupMode.projectStatus:
        final rows = [
          for (final e in _byStatus)
            {
              'name': _statusLabel(e['status']),
              'total': (e['total'] as num?)?.toInt() ?? 0,
            },
        ];
        return _buildRankList(
          rows: rows,
          emptyText: '所选时间范围内还没有收款记录',
        );
    }
  }

  String _statusLabel(Object? status) {
    if (status == null) return '其他 / 已删除项目';
    final idx = (status as num).toInt();
    if (idx >= 0 && idx < ProjectStatus.values.length) {
      return ProjectStatus.values[idx].label;
    }
    return '其他';
  }

  Widget _buildRankList({
    required List<Map<String, Object?>> rows,
    required String emptyText,
  }) {
    if (rows.isEmpty) {
      return const Card(
        margin: EdgeInsets.symmetric(horizontal: 16),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text('暂无数据',
                style: TextStyle(color: AppTheme.textSub)),
          ),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++)
            _ContribRow(
              rank: i + 1,
              name: (rows[i]['name'] as String?) ?? '',
              total: (rows[i]['total'] as num?)?.toInt() ?? 0,
            ),
        ],
      ),
    );
  }
}

// 单指标数值展示
class _Metric extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  const _Metric({
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppTheme.textSub)),
          const SizedBox(height: 4),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ],
      ),
    );
  }
}

class _ContribRow extends StatelessWidget {
  final int rank;
  final String name;
  final int total;
  const _ContribRow({
    required this.rank,
    required this.name,
    required this.total,
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
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
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
// 统计看板口径：草稿/作废报价不参与（已由 DB 层过滤），待收余额即应收欠款。
// 数值非法（负数）一律按 0 处理，防止脏数据扭曲统计结果。

// 实际已收款（分）。负数兜底置 0。
int calcReceivedAmount(Map<String, int> summary) {
  final paid = summary['paid'] ?? 0;
  return paid < 0 ? 0 : paid;
}

// 应收欠款（分）。按业务状态区分：
//  - 待收余额为 0：全款已结清，无应收欠款；
//  - 待收余额 > 0：部分收款或全款未收，应收欠款即为待收余额；
//  - 数值非法（<0）一律兜底为 0。
int calcReceivableAmount(Map<String, int> summary) {
  final pending = summary['pending'] ?? 0;
  if (pending <= 0) return 0;
  return pending;
}

/// 第15批 VIP 门禁引导组件（不隐藏入口，免费用户进入时展示并引导升级）。
Widget _vipGate(BuildContext context,
    {required String appBarTitle,
    required String feature,
    required String desc}) {
  return Scaffold(
    appBar: AppBar(title: Text(appBarTitle)),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: AppTheme.primary),
            const SizedBox(height: 16),
            Text('$feature为专业版专属',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(desc,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.textSub, fontSize: 13)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PaywallPage(
                    title: '升级专业版',
                    desc: '解锁全部高级经营功能',
                  ),
                ),
              ),
              icon: const Icon(Icons.workspace_premium),
              label: const Text('升级 VIP 解锁'),
            ),
          ],
        ),
      ),
    ),
  );
}
