import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../constants.dart';
import '../theme.dart';
import '../widgets/date_range_picker_sheet.dart';
import '../widgets/range_filter_bar.dart';
import '../widgets/app_ui.dart';

/// 收入记录页：按 年 / 月 / 周 / 自定义日期区间 筛选历史收入，
/// 展示所选时间段的收入合计与该时间段收款明细。
/// 入口：看板「本月收入」卡片点击进入。
class IncomeHistoryPage extends StatefulWidget {
const IncomeHistoryPage({super.key});

  @override
  State<IncomeHistoryPage> createState() => _IncomeHistoryPageState();
}

/// 筛选模式（枚举本身仅定义可选模式，界面展示顺序见 RangeFilterBar 的 items）
enum _RangeMode { month, week, year, range }

class _IncomeHistoryPageState extends State<IncomeHistoryPage> {
  final _fmt = NumberFormat('#,##0.00');

  _RangeMode _mode = _RangeMode.month;
  int _total = 0; // 单位分，展示时统一 /100
  List<_IncomeRow> _rows = [];
  String _summaryTitle = '';

  // 模式各自的状态
  late int _mYear; // 月模式：年
  late int _mMonth; // 月模式：月
  late int _yYear; // 年模式：年
  late DateTime _weekAnchor; // 周模式：锚定在所选周内的任意一天
  late DateTime _rStart; // 区间模式：起始日
  late DateTime _rEnd; // 区间模式：结束日

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _mYear = now.year;
    _mMonth = now.month;
    _yYear = now.year;
    final ws = _weekStartOf(now);
    _weekAnchor = ws;
    _rStart = DateTime(now.year, now.month, 1);
    _rEnd = now;
    _load();
  }

  /// 某天所在自然周（周一开始）的周一
  static DateTime _weekStartOf(DateTime d) {
    final d0 = DateTime(d.year, d.month, d.day);
    final dow = d0.weekday; // 1=周一 ... 7=周日
    return d0.subtract(Duration(days: dow - 1));
  }

  /// 计算当前模式的时间范围 [startMs, endMs) 与汇总标题
  (int, int, String) _rangeOf() {
    switch (_mode) {
      case _RangeMode.month:
        final s = DateTime(_mYear, _mMonth, 1);
        final e = DateTime(_mYear, _mMonth + 1, 1);
        return (s.millisecondsSinceEpoch, e.millisecondsSinceEpoch, L10n.instance.t('i18n_005', args: {'v0':'$_mYear', 'v1':'$_mMonth'}));
      case _RangeMode.week:
        final ws = _weekStartOf(_weekAnchor);
        final we = ws.add(Duration(days: 6));
        final s = ws;
        final e = we.add(Duration(days: 1));
        return (
          s.millisecondsSinceEpoch,
          e.millisecondsSinceEpoch,
          L10n.instance.t('i18n_027', args: {'v0':'${ws.month}', 'v1':'${ws.day}', 'v2':'${we.month}', 'v3':'${we.day}'}),
        );
      case _RangeMode.year:
        final s = DateTime(_yYear, 1, 1);
        final e = DateTime(_yYear + 1, 1, 1);
        return (s.millisecondsSinceEpoch, e.millisecondsSinceEpoch, L10n.instance.t('i18n_007', args: {'v0':'$_yYear'}));
      case _RangeMode.range:
        final s = DateTime(_rStart.year, _rStart.month, _rStart.day);
        final e = DateTime(_rEnd.year, _rEnd.month, _rEnd.day)
            .add(Duration(days: 1));
        return (
          s.millisecondsSinceEpoch,
          e.millisecondsSinceEpoch,
          L10n.instance.t('i18n_019', args: {'v0': _rangeLabel(_rStart, _rEnd)}),
        );
    }
  }

  Future<void> _load() async {
    final (s, e, title) = _rangeOf();
    final db = AppDb.instance;
    final results = await Future.wait([
      db.paidTotalInRange(s, e),
      db.paymentsInRange(s, e),
    ]);
    final total = results[0] as int; // paidTotalInRange 返回分，非 double
    final raw = results[1] as List<Map<String, Object?>>;
    if (!mounted) return;
    setState(() {
      _total = total;
      _summaryTitle = title;
      _rows = raw.map(_IncomeRow.fromMap).toList();
    });
  }

  // ---------- 导航动作 ----------

  void _shift(int delta) {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.month:
        var y = _mYear;
        var m = _mMonth + delta;
        while (m < 1) {
          m += 12;
          y -= 1;
        }
        while (m > 12) {
          m -= 12;
          y += 1;
        }
        if (y < 2000 || y > now.year + 1) return;
        setState(() {
          _mYear = y;
          _mMonth = m;
        });
      case _RangeMode.week:
        final next = _weekAnchor.add(Duration(days: 7 * delta));
        if (next.year < 2000) return;
        setState(() => _weekAnchor = next);
      case _RangeMode.year:
        final y = _yYear + delta;
        if (y < 2000 || y > now.year + 1) return;
        setState(() => _yYear = y);
      case _RangeMode.range:
        final s = _rStart.add(Duration(days: 7 * delta));
        final e = _rEnd.add(Duration(days: 7 * delta));
        if (s.year < 2000) return;
        setState(() {
          _rStart = s;
          _rEnd = e;
        });
    }
    _load();
  }

  /// 当前时间范围的展示标签
  String get _navLabel => switch (_mode) {
        _RangeMode.month => L10n.instance.t('i18n_004', args: {'v0':'$_mYear', 'v1':'$_mMonth'}),
        _RangeMode.week => _weekNavLabel,
        _RangeMode.year => L10n.instance.t('i18n_006', args: {'v0':'$_yYear'}),
        _RangeMode.range => _rangeLabel(_rStart, _rEnd),
      };

  /// 起止区间文案：起止两端都带年份（同年也不省略，保证信息完整）
  String _rangeLabel(DateTime s, DateTime e) {
    return L10n.instance.t('i18n_025', args: {'v0':'${s.year}', 'v1':'${s.month}', 'v2':'${s.day}', 'v3':'${e.year}', 'v4':'${e.month}', 'v5':'${e.day}'});
  }

  String get _weekNavLabel {
    final ws = _weekStartOf(_weekAnchor);
    final we = ws.add(Duration(days: 6));
    return _rangeLabel(ws, we);
  }

  /// 当前所选范围是否为"当前"范围（用于“回到当前”按钮显隐）
  bool get _isCurrent {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.month:
        return _mYear == now.year && _mMonth == now.month;
      case _RangeMode.week:
        return _weekStartOf(_weekAnchor) == _weekStartOf(now);
      case _RangeMode.year:
        return _yYear == now.year;
      case _RangeMode.range:
        final mStart = DateTime(now.year, now.month, 1);
        final today = DateTime(now.year, now.month, now.day);
        return _rStart == mStart && _rEnd == today;
    }
  }

  Future<void> _pickCenter() async {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.month:
        final picked = await showAppSheet<DateTime>(
          context,
          builder: (_) => _MonthPickerSheet(year: _mYear, month: _mMonth),
        );
        if (picked == null) return;
        setState(() {
          _mYear = picked.year;
          _mMonth = picked.month;
        });
      case _RangeMode.week:
        final picked = await showDatePicker(
          context: context,
          initialDate: _weekAnchor,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year + 1, 12, 31),
          helpText: L10n.instance.t('i18n_603'),
        );
        if (picked == null) return;
        setState(() => _weekAnchor = picked);
      case _RangeMode.year:
        final picked = await showDatePicker(
          context: context,
          initialDate: DateTime(_yYear, 1, 1),
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year + 1, 12, 31),
          initialDatePickerMode: DatePickerMode.year,
          helpText: L10n.instance.t('i18n_610'),
        );
        if (picked == null) return;
        setState(() => _yYear = picked.year);
      case _RangeMode.range:
        // 自绘起止日期弹层：年份可直接点选，避免全屏日历滑动找年份的繁琐与灰屏
        final picked = await showDateRangeSheet(
          context: context,
          start: _rStart,
          end: _rEnd,
          firstDate: DateTime(2000, 1, 1),
          lastDate: DateTime(now.year + 1, 12, 31),
          title: L10n.instance.t('common_pick_range'),
        );
        if (picked == null) return;
        setState(() {
          _rStart = picked.start;
          _rEnd = picked.end;
        });
    }
    _load();
  }

  void _goCurrent() {
    final now = DateTime.now();
    switch (_mode) {
      case _RangeMode.month:
        _mYear = now.year;
        _mMonth = now.month;
      case _RangeMode.week:
        _weekAnchor = _weekStartOf(now);
      case _RangeMode.year:
        _yYear = now.year;
      case _RangeMode.range:
        _rStart = DateTime(now.year, now.month, 1);
        _rEnd = now;
    }
    _load();
  }

  // ---------- 视图 ----------

  @override
  Widget build(BuildContext context) {
    final canGoCurrent = !_isCurrent;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('income_history_title'))),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          // 筛选模式切换（与收入统计页共用 RangeFilterBar：左对齐、间距一致、无图标）
          RangeFilterBar<_RangeMode>(
            items: [
              RangeFilterItem(_RangeMode.week, L10n.instance.t('i18n_354')),
              RangeFilterItem(_RangeMode.month, L10n.instance.t('i18n_358')),
              RangeFilterItem(_RangeMode.year, L10n.instance.t('i18n_356')),
              RangeFilterItem(_RangeMode.range, L10n.instance.t('common_custom')),
            ],
            value: _mode,
            onChanged: (mode) {
              if (_mode == mode) return;
              setState(() => _mode = mode);
              _load();
            },
          ),
          // 时间切换条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => _shift(-1),
                  icon: Icon(Icons.chevron_left),
                  tooltip: switch (_mode) {
                    _RangeMode.month => L10n.instance.t('income_history_page_prev_month'),
                    _RangeMode.week => L10n.instance.t('i18n_061'),
                    _RangeMode.year => L10n.instance.t('i18n_062'),
                    _RangeMode.range => L10n.instance.t('i18n_149'),
                  },
                ),
                Expanded(
                  child: InkWell(
                    onTap: _pickCenter,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        _navLabel,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textMain,
                        ),
                      ),
                    ),
                  ),
                ),
                if (canGoCurrent)
                  IconButton(
                    onPressed: _goCurrent,
                    icon: Icon(Icons.today),
                    tooltip: switch (_mode) {
                      _RangeMode.month => L10n.instance.t('i18n_186'),
                      _RangeMode.week => L10n.instance.t('i18n_185'),
                      _RangeMode.year => L10n.instance.t('i18n_184'),
                      _RangeMode.range => L10n.instance.t('i18n_186'),
                    },
                  )
                else
                  SizedBox(width: 48),
                IconButton(
                  onPressed: () => _shift(1),
                  icon: Icon(Icons.chevron_right),
                  tooltip: switch (_mode) {
                    _RangeMode.month => L10n.instance.t('income_history_page_next_month'),
                    _RangeMode.week => L10n.instance.t('i18n_072'),
                    _RangeMode.year => L10n.instance.t('i18n_073'),
                    _RangeMode.range => L10n.instance.t('i18n_174'),
                  },
                ),
              ],
            ),
          ),
          // 收入汇总卡
          _SummaryCard(amount: _total, title: _summaryTitle, fmt: _fmt, count: _rows.length),
          SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text(
              L10n.instance.t('i18n_385'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textMain),
            ),
          ),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  _mode == _RangeMode.month && _isCurrent
                      ? L10n.instance.t('i18n_455')
                      : L10n.instance.t('i18n_564'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSub, height: 1.6),
                ),
              ),
            )
          else
            ..._rows.map((r) => _IncomeRowTile(row: r, fmt: _fmt)),
        ],
      ),
    );
  }
}

/// 单条收款明细（数据库行解析）
class _IncomeRow {
  final int projectId;
  final String projectTitle;
  final int amount; // 分
  final PayType type;
  final String typeLabel;
  final int paidAt;
  final String note;

  _IncomeRow({
    required this.projectId,
    required this.projectTitle,
    required this.amount,
    required this.type,
    required this.typeLabel,
    required this.paidAt,
    required this.note,
  });

  factory _IncomeRow.fromMap(Map<String, Object?> m) => _IncomeRow(
        projectId: m['project_id'] as int,
        projectTitle: m['project_title'] as String,
        amount: ((m['amount'] as num?) ?? 0).toInt(),
        type: _payTypeOf(m['type']),
        typeLabel: (m['type_label'] as String?) ?? '',
        paidAt: m['paid_at'] as int,
        note: (m['note'] as String?) ?? '',
      );

  /// 收款类型安全解析：库里脏值或越界一律回退到「全额」，不抛 RangeError
  static PayType _payTypeOf(Object? v) {
    final i = v is num ? v.toInt() : -1;
    if (i < 0 || i >= PayType.values.length) return PayType.full;
    return PayType.values[i];
  }

  /// 展示用的类型名（自定义类型回退到 type_label，再回退到枚举 label）
  String get displayType {
    if (type == PayType.custom) {
      final l = typeLabel.trim();
      return l.isEmpty ? L10n.instance.t('common_custom') : l;
    }
    return type.label;
  }
}

class _IncomeRowTile extends StatelessWidget {
  final _IncomeRow row;
  final NumberFormat fmt;
const   _IncomeRowTile({required this.row, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(row.paidAt);
    return Card(
      child: ListTile(
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${dt.day}',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              Text(L10n.instance.t('income_history_month', args: {'dt.month': '${dt.month}'}),
                  style: TextStyle(fontSize: 10, color: AppTheme.primary.withValues(alpha: 0.7))),
            ],
          ),
        ),
        title: Text(row.projectTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          row.note.isEmpty ? row.displayType : '${row.displayType} · ${row.note}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppTheme.textSub, fontSize: 12),
        ),
        trailing: Text(
          '+¥${fmt.format(row.amount / 100)}',
          style: TextStyle(
            color: AppTheme.primary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int amount; // 分
  final String title;
  final int count;
  final NumberFormat fmt;
const _SummaryCard({
    required this.amount,
    required this.title,
    required this.count,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
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
          Text(title,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          SizedBox(height: 8),
          Text('¥${fmt.format(amount / 100)}',
              style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
          SizedBox(height: 14),
          Text(L10n.instance.t('income_history_total_line', args: {'count':'$count'}), style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
        ],
      ),
    );
  }
}

/// 月份选择面板
class _MonthPickerSheet extends StatefulWidget {
  final int year;
  final int month;
const _MonthPickerSheet({required this.year, required this.month});

  @override
  State<_MonthPickerSheet> createState() => _MonthPickerSheetState();
}

class _MonthPickerSheetState extends State<_MonthPickerSheet> {
  late int _year = widget.year;
  late int _month = widget.month;

  void _shiftYear(int delta) {
    final y = _year + delta;
    if (y < 2000 || y > DateTime.now().year + 1) return;
    setState(() => _year = y);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final int monthColumns = MediaQuery.sizeOf(context).width >= 600 ? 6 : 4;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => _shiftYear(-1),
                  icon: Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(L10n.instance.t('income_history_year', args: {'_year':'$_year'}),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  onPressed: () => _shiftYear(1),
                  icon: Icon(Icons.chevron_right),
                ),
              ],
            ),
            GridView.count(
              crossAxisCount: monthColumns,
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.1,
              children: List.generate(12, (i) {
                final m = i + 1;
                final selected = _year == widget.year && m == widget.month;
                final isFuture = _year == now.year && m > now.month;
                return InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  onTap: isFuture ? null : () => setState(() => _month = m),
                  child: Container(
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.primary
                          : isFuture
                              ? Colors.transparent
                              : AppTheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      L10n.instance.t('i18n_008', args: {'v0':'$m'}),
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : isFuture
                                ? AppTheme.textSub.withValues(alpha: 0.4)
                                : AppTheme.textMain,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }),
            ),
            SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, DateTime(_year, _month)),
                child: Text(L10n.instance.t('common_ok')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
