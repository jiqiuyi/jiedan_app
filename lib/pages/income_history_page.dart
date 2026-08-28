import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../constants.dart';
import '../theme.dart';

/// 收入记录页：按 年 / 月 / 周 / 自定义日期区间 筛选历史收入，
/// 展示所选时间段的收入合计与该时间段收款明细。
/// 入口：看板「本月收入」卡片点击进入。
class IncomeHistoryPage extends StatefulWidget {
  const IncomeHistoryPage({super.key});

  @override
  State<IncomeHistoryPage> createState() => _IncomeHistoryPageState();
}

/// 筛选模式
enum _RangeMode { month, week, year, range }

class _IncomeHistoryPageState extends State<IncomeHistoryPage> {
  final _fmt = NumberFormat('#,##0.00');

  _RangeMode _mode = _RangeMode.month;
  double _total = 0;
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
        return (s.millisecondsSinceEpoch, e.millisecondsSinceEpoch, '$_mYear年$_mMonth月收入');
      case _RangeMode.week:
        final ws = _weekStartOf(_weekAnchor);
        final we = ws.add(const Duration(days: 6));
        final s = ws;
        final e = we.add(const Duration(days: 1));
        return (
          s.millisecondsSinceEpoch,
          e.millisecondsSinceEpoch,
          '${ws.month}月${ws.day}日 - ${we.month}月${we.day}日 收入',
        );
      case _RangeMode.year:
        final s = DateTime(_yYear, 1, 1);
        final e = DateTime(_yYear + 1, 1, 1);
        return (s.millisecondsSinceEpoch, e.millisecondsSinceEpoch, '$_yYear年收入');
      case _RangeMode.range:
        final s = DateTime(_rStart.year, _rStart.month, _rStart.day);
        final e = DateTime(_rEnd.year, _rEnd.month, _rEnd.day)
            .add(const Duration(days: 1));
        return (
          s.millisecondsSinceEpoch,
          e.millisecondsSinceEpoch,
          '${_rStart.month}月${_rStart.day}日 - ${_rEnd.month}月${_rEnd.day}日 收入',
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
    final total = results[0] as double;
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
        _RangeMode.month => '$_mYear年 $_mMonth月',
        _RangeMode.week => _weekNavLabel,
        _RangeMode.year => '$_yYear年',
        _RangeMode.range =>
          '${_rStart.month}月${_rStart.day}日 - ${_rEnd.month}月${_rEnd.day}日',
      };

  String get _weekNavLabel {
    final ws = _weekStartOf(_weekAnchor);
    final we = ws.add(const Duration(days: 6));
    if (ws.year == we.year) {
      return '${ws.year}年${ws.month}月${ws.day}日 - ${we.month}月${we.day}日';
    }
    return '${ws.year}年${ws.month}月${ws.day}日 - ${we.year}年${we.month}月${we.day}日';
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
        final picked = await showModalBottomSheet<DateTime>(
          context: context,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
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
          helpText: '选择一周内的任意一天',
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
          helpText: '选择年份',
        );
        if (picked == null) return;
        setState(() => _yYear = picked.year);
      case _RangeMode.range:
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year + 1, 12, 31),
          initialDateRange: DateTimeRange(start: _rStart, end: _rEnd),
          helpText: '选择起止日期',
          saveText: '确定',
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
      appBar: AppBar(title: const Text('收入记录')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          // 筛选模式切换
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final mode in _RangeMode.values) ...[
                  _ModeChip(
                    label: switch (mode) {
                      _RangeMode.month => '按月',
                      _RangeMode.week => '按周',
                      _RangeMode.year => '按年',
                      _RangeMode.range => '自定义',
                    },
                    selected: _mode == mode,
                    onTap: () {
                      if (_mode == mode) return;
                      setState(() => _mode = mode);
                      _load();
                    },
                  ),
                  if (mode != _RangeMode.values.last) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          // 时间切换条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: switch (_mode) {
                    _RangeMode.month => '上一月',
                    _RangeMode.week => '上一周',
                    _RangeMode.year => '上一年',
                    _RangeMode.range => '前7天',
                  },
                ),
                Expanded(
                  child: InkWell(
                    onTap: _pickCenter,
                    borderRadius: BorderRadius.circular(12),
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
                    icon: const Icon(Icons.today),
                    tooltip: switch (_mode) {
                      _RangeMode.month => '回到本月',
                      _RangeMode.week => '回到本周',
                      _RangeMode.year => '回到今年',
                      _RangeMode.range => '回到本月',
                    },
                  )
                else
                  const SizedBox(width: 48),
                IconButton(
                  onPressed: () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: switch (_mode) {
                    _RangeMode.month => '下一月',
                    _RangeMode.week => '下一周',
                    _RangeMode.year => '下一年',
                    _RangeMode.range => '后7天',
                  },
                ),
              ],
            ),
          ),
          // 收入汇总卡
          _SummaryCard(amount: _total, title: _summaryTitle, fmt: _fmt, count: _rows.length),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text(
              '收款明细',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textMain),
            ),
          ),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  _mode == _RangeMode.month && _isCurrent
                      ? '本月还没有收款记录\n登记收款后会显示在这里'
                      : '该时间段没有收款记录',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textSub, height: 1.6),
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

/// 筛选模式 chip
class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? Colors.white : AppTheme.textMain,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 单条收款明细（数据库行解析）
class _IncomeRow {
  final int projectId;
  final String projectTitle;
  final double amount;
  final PayType type;
  final int paidAt;
  final String note;

  _IncomeRow({
    required this.projectId,
    required this.projectTitle,
    required this.amount,
    required this.type,
    required this.paidAt,
    required this.note,
  });

  factory _IncomeRow.fromMap(Map<String, Object?> m) => _IncomeRow(
        projectId: m['project_id'] as int,
        projectTitle: m['project_title'] as String,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        type: PayType.values[m['type'] as int],
        paidAt: m['paid_at'] as int,
        note: (m['note'] as String?) ?? '',
      );
}

class _IncomeRowTile extends StatelessWidget {
  final _IncomeRow row;
  final NumberFormat fmt;
  const _IncomeRowTile({required this.row, required this.fmt});

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
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${dt.day}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              Text('${dt.month}月',
                  style: TextStyle(fontSize: 10, color: AppTheme.primary.withValues(alpha: 0.7))),
            ],
          ),
        ),
        title: Text(row.projectTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          row.note.isEmpty ? row.type.label : '${row.type.label} · ${row.note}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
        ),
        trailing: Text(
          '+¥${fmt.format(row.amount)}',
          style: const TextStyle(
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
  final double amount;
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
          Text(title,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          const SizedBox(height: 8),
          Text('¥${fmt.format(amount)}',
              style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Text('$count 笔收款合计', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
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
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text('$_year 年',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  onPressed: () => _shiftYear(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.1,
              children: List.generate(12, (i) {
                final m = i + 1;
                final selected = _year == widget.year && m == widget.month;
                final isFuture = _year == now.year && m > now.month;
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: isFuture ? null : () => setState(() => _month = m),
                  child: Container(
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.primary
                          : isFuture
                              ? Colors.transparent
                              : AppTheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$m月',
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, DateTime(_year, _month)),
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
