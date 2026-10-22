import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../theme.dart';
import '../widgets/date_range_picker_sheet.dart';
import '../widgets/range_filter_bar.dart';
import 'paywall_page.dart';
import '../widgets/app_ui.dart';

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
  String _rangeTitle = L10n.instance.t('i18n_593');

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
        return L10n.instance.t('i18n_022', args: {'v0':'${now.year}', 'v1':'${now.month}'});
      case _RangeMode.lastMonth:
        final m = now.month == 1 ? 12 : now.month - 1;
        final y = now.month == 1 ? now.year - 1 : now.year;
        return L10n.instance.t('i18n_013', args: {'v0':'$y', 'v1':'$m'});
      case _RangeMode.last12:
        return L10n.instance.t('i18n_593');
      case _RangeMode.custom:
        // 与「收入记录」页共用同一套区间文案：起止两端都带年份。
        // 注意：此处必须用字符串拼接，不能再走 NumberFormat 格式化 DateTime，
        // 否则运行期会抛 NoSuchMethodError(isNegative) 导致整页白屏。
        return L10n.instance.t('i18n_018', args: {'v0':'${_rStart.year}', 'v1':'${_rStart.month}', 'v2':'${_rStart.day}'}) +
            L10n.instance.t('i18n_017', args: {'v0':'${_rEnd.year}', 'v1':'${_rEnd.month}', 'v2':'${_rEnd.day}'});
    }
  }

  @override
  Widget build(BuildContext context) {
    // 第15批：统计·高级分析（自定义区间/月度对比/分类汇总）加 VIP 门禁，
    // 不隐藏入口，免费用户进入即见升级引导。
    if (!AppState.instance.isPro) {
      return _vipGate(
        context,
        appBarTitle: L10n.instance.t('income_stats_page_stats_dashboard'),
        feature: L10n.instance.t('i18n_535'),
        desc: L10n.instance.t('i18n_544'),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('income_stats_title'))),
      body: _loading
          ? AppLoading()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                children: [
                  _buildRangeSelector(),
                  SizedBox(height: 6),
                  _buildReceivableCard(),
                  SizedBox(height: 6),
                  _buildRangeSummaryCard(),
                  if (_mode == _RangeMode.last12) ...[
                    SizedBox(height: 6),
                    Padding(
                      padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
                      child: Text(L10n.instance.t('income_stats_12m'),
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textMain)),
                    ),
                    _MonthlyBarChart(data: _monthly),
                  ],
                  SizedBox(height: 6),
                  _buildGroupSummary(),
                  Padding(
                    padding: EdgeInsets.fromLTRB(18, 12, 18, 4),
                    child: Text(
                      L10n.instance.t('i18n_158') +
                      L10n.instance.t('i18n_296'),
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.textSub),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // 时间范围筛选条：本月 / 上月 / 近12个月 / 自定义。
  // 统一使用 RangeFilterBar：左对齐、间距一致、按内容宽度排列（不做等宽拉伸）；
  // 自定义区间入口单独一行展示当前区间，避免文字挤压筛选行。
  Widget _buildRangeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RangeFilterBar<_RangeMode>(
          items: [
            RangeFilterItem(_RangeMode.month, L10n.instance.t('income_stats_page_this_month')),
            RangeFilterItem(_RangeMode.lastMonth, L10n.instance.t('i18n_068')),
            RangeFilterItem(_RangeMode.last12, L10n.instance.t('i18n_593')),
            RangeFilterItem(_RangeMode.custom, L10n.instance.t('common_custom')),
          ],
          value: _mode,
          onChanged: (mode) {
            if (_mode == mode) return;
            setState(() => _mode = mode);
            _load();
          },
        ),
        if (_mode == _RangeMode.custom) ...[
          SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: InkWell(
              onTap: _pickCustomRange,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: [
                    Icon(Icons.date_range,
                        size: 16, color: AppTheme.primary),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        L10n.instance.t('i18n_536', args: {'v0': _titleOf()}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 16, color: AppTheme.textSub),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    // 自绘起止日期弹层：点起点→自动切终点，年份可直接点选，避免全屏日历灰屏问题
    final range = await showDateRangeSheet(
      context: context,
      start: _rStart,
      end: _rEnd,
      firstDate: DateTime(now.year - 10, 1, 1),
      lastDate: now,
      title: L10n.instance.t('income_stats_pick_range'),
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
            ? LinearGradient(
                colors: [Color(0xFF27AE60), Color(0xFF2EBD85)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : LinearGradient(
                colors: [Color(0xFFE67E22), Color(0xFFF39C12)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
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
              SizedBox(width: 6),
              Text(
                cleared ? L10n.instance.t('i18n_297') : L10n.instance.t('i18n_295'),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9), fontSize: 13),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            '¥${cleared ? '0.00' : receivableText}',
            style: TextStyle(
                color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 8),
          Text(
            cleared
                ? L10n.instance.t('i18n_411')
                : L10n.instance.t('i18n_131', args: {'v0': receivableText}),
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
            Text(L10n.instance.t('income_stats_range_stats', args: {'_rangeTitle':_rangeTitle}),
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    color: AppTheme.accent,
                    label: L10n.instance.t('income_stats_range_income', args: {'_rangeTitle':_rangeTitle}),
                    value: '¥${_fmt.format(_paidTotal / 100)}',
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: _Metric(
                    color: AppTheme.primary,
                    label: L10n.instance.t('income_stats_range_quotes', args: {'_rangeTitle':_rangeTitle}),
                    value: '¥${_fmt.format(_quoteTotal / 100)}',
                  ),
                ),
              ],
            ),
            if (_mode == _RangeMode.month ||
                _mode == _RangeMode.lastMonth) ...[
              SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    delta >= 0
                        ? Icons.trending_up
                        : Icons.trending_down,
                    size: 16,
                    color: delta >= 0
                        ? Color(0xFF27AE60)
                        : Color(0xFFE74C3C),
                  ),
                  SizedBox(width: 6),
                  Text(
                    _mode == _RangeMode.month
                        ? '${L10n.instance.t('income_stats_vs_last_month', args: {'v0': delta >= 0 ? '+' : ''})}'
                            '${_fmt.format(delta / 100)}'
                            '（${(deltaRatio * 100).toStringAsFixed(1)}%）'
                        : '${L10n.instance.t('income_stats_last_vs_this', args: {'v0': delta >= 0 ? '+' : ''})}'
                            '${_fmt.format(delta / 100)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: delta >= 0
                            ? Color(0xFF27AE60)
                            : Color(0xFFE74C3C),
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
        Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text(L10n.instance.t('income_stats_category'),
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
                (_GroupMode.customer, L10n.instance.t('i18n_355')),
                (_GroupMode.quoteType, L10n.instance.t('i18n_357')),
                (_GroupMode.projectStatus, L10n.instance.t('i18n_360')),
              ])
                AppFilterChip(
                  label: label,
                  selected: _group == g,
                  onTap: () => setState(() => _group = g),
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
          emptyText: L10n.instance.t('i18n_340'),
        );
      case _GroupMode.quoteType:
        final rows = [
          for (final e in _byType)
            {
              'name': ((e['type'] as String?) == 'simple' ? L10n.instance.t('quote_simple') : L10n.instance.t('quote_detailed')),
              'total': (e['total'] as num?)?.toInt() ?? 0,
            },
        ];
        return _buildRankList(
          rows: rows,
          emptyText: L10n.instance.t('i18n_341'),
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
          emptyText: L10n.instance.t('i18n_340'),
        );
    }
  }

  String _statusLabel(Object? status) {
    if (status == null) return '${L10n.instance.t('common_other')} / ${L10n.instance.t('common_deleted_project')}';
    final idx = (status as num).toInt();
    if (idx >= 0 && idx < ProjectStatus.values.length) {
      return ProjectStatus.values[idx].label;
    }
    return L10n.instance.t('common_other');
  }

  Widget _buildRankList({
    required List<Map<String, Object?>> rows,
    required String emptyText,
  }) {
    if (rows.isEmpty) {
      return Card(
        margin: EdgeInsets.symmetric(horizontal: 16),
        child: AppEmpty(
          icon: Icons.inbox_outlined,
          title: L10n.instance.t('common_empty'),
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: AppTheme.textSub)),
          SizedBox(height: 4),
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
          SizedBox(width: 12),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          SizedBox(width: 12),
          Text('¥${fmt.format(total / 100)}',
              style: TextStyle(
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
                                    top: Radius.circular(AppRadius.xxs)),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: 6),
              Row(
                children: [
                  for (final e in data)
                    Expanded(
                      child: Text(
                        L10n.instance.t('income_stats_month_tpl', args: {'v0':'${e['month']}'}),
                        textAlign: TextAlign.center,
                        style: TextStyle(
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
            Icon(Icons.lock_outline, size: 64, color: AppTheme.primary),
            SizedBox(height: 16),
            Text(L10n.instance.t('paywall_feature_pro_only', args: {'feature':feature}),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            SizedBox(height: 8),
            Text(desc,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.textSub, fontSize: 13)),
            SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PaywallPage(
                    title: L10n.instance.t('paywall_upgrade_pro'),
                    desc: L10n.instance.t('i18n_554'),
                  ),
                ),
              ),
              icon: Icon(Icons.workspace_premium),
              label: Text(L10n.instance.t('paywall_upgrade_vip')),
            ),
          ],
        ),
      ),
    ),
  );
}
