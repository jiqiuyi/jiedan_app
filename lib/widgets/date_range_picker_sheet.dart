import 'package:flutter/material.dart';

import '../theme.dart';

/// 通用「起止日期」选择弹层（v1.42.0 新增）。
///
/// 背景：系统自带的 showDateRangePicker 为全屏模式，进入后仅剩灰底、日历区
/// 不渲染（在深/浅色主题与部分机型上均有该问题），且跨年选择需反复滑动月份，
/// 年份极难定位。此处改为自绘底部弹层：
///  - 星期表头 + 月历网格，点起点 → 自动切到终点，两步即可选完区间；
///  - 顶部「年 / 月」可点，直接弹出年份网格，跨年选择一步到位；
///  - 越界日期自动置灰，起止顺序自动纠正，不产生非法区间。
Future<DateTimeRange?> showDateRangeSheet({
  required BuildContext context,
  required DateTime start,
  required DateTime end,
  DateTime? firstDate,
  DateTime? lastDate,
  String title = '选择起止日期',
}) {
  return showModalBottomSheet<DateTimeRange>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DateRangeSheet(
      start: start,
      end: end,
      firstDate: firstDate ?? DateTime(2000, 1, 1),
      lastDate: lastDate ?? DateTime.now(),
      title: title,
    ),
  );
}

class _DateRangeSheet extends StatefulWidget {
  final DateTime start;
  final DateTime end;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;

  const _DateRangeSheet({
    required this.start,
    required this.end,
    required this.firstDate,
    required this.lastDate,
    required this.title,
  });

  @override
  State<_DateRangeSheet> createState() => _DateRangeSheetState();
}

class _DateRangeSheetState extends State<_DateRangeSheet> {
  late DateTime _start;
  late DateTime _end;

  /// 当前正在点选的目标：false=起点，true=终点
  bool _editingEnd = false;

  /// 年 / 月视图切换：false=月历，true=年份网格
  bool _yearMode = false;

  /// 月历当前浏览的「年 / 月」
  late int _viewYear;
  late int _viewMonth;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime get _minDay => _day(widget.firstDate);
  DateTime get _maxDay => _day(widget.lastDate);

  @override
  void initState() {
    super.initState();
    _start = _clampDay(widget.start);
    _end = _clampDay(widget.end);
    if (_end.isBefore(_start)) _end = _start;
    _viewYear = _end.year;
    _viewMonth = _end.month;
  }

  DateTime _clampDay(DateTime d) {
    final v = _day(d);
    if (v.isBefore(_minDay)) return _minDay;
    if (v.isAfter(_maxDay)) return _maxDay;
    return v;
  }

  bool _inRange(DateTime d) =>
      !d.isBefore(_start) && !d.isAfter(_end);

  void _shiftMonth(int delta) {
    var y = _viewYear;
    var m = _viewMonth + delta;
    while (m < 1) {
      m += 12;
      y -= 1;
    }
    while (m > 12) {
      m -= 12;
      y += 1;
    }
    if (y < _minDay.year || y > _maxDay.year) return;
    setState(() {
      _viewYear = y;
      _viewMonth = m;
    });
  }

  void _onDayTap(DateTime d) {
    if (d.isBefore(_minDay) || d.isAfter(_maxDay)) return;
    setState(() {
      if (!_editingEnd) {
        _start = d;
        if (_end.isBefore(d)) _end = d;
        _editingEnd = true;
      } else {
        _end = d;
        if (d.isBefore(_start)) _start = d;
      }
    });
  }

  void _pickYear(int y) {
    setState(() {
      _viewYear = y;
      _yearMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.86;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                _buildEdgeRow(
                  label: '开始',
                  value: _start,
                  active: !_editingEnd,
                  onTap: () => setState(() => _editingEnd = false),
                ),
                const SizedBox(height: 8),
                _buildEdgeRow(
                  label: '结束',
                  value: _end,
                  active: _editingEnd,
                  onTap: () => setState(() => _editingEnd = true),
                ),
                const SizedBox(height: 6),
                Text(
                  _editingEnd ? '请点选结束日期' : '请点选开始日期',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
                ),
                const SizedBox(height: 6),
                if (_yearMode) _buildYearGrid() else _buildMonthView(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(
                            context, DateTimeRange(start: _start, end: _end)),
                        child: const Text('确定'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEdgeRow({
    required String label,
    required DateTime value,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.primary.withValues(alpha: 0.08)
              : AppTheme.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? AppTheme.primary : const Color(0xFFE4E7EF),
            width: active ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? AppTheme.primary : AppTheme.textSub)),
            const SizedBox(width: 12),
            Text(
              '${value.year}年${value.month}月${value.day}日',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYearGrid() {
    final years = [
      for (int y = _minDay.year; y <= _maxDay.year; y++) y,
    ];
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.1,
      children: [
        for (final y in years)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _pickYear(y),
            child: Container(
              decoration: BoxDecoration(
                color: y == _viewYear
                    ? AppTheme.primary
                    : AppTheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(
                '$y年',
                style: TextStyle(
                  fontSize: 13,
                  color: y == _viewYear ? Colors.white : AppTheme.textMain,
                  fontWeight:
                      y == _viewYear ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMonthView() {
    final firstDay = DateTime(_viewYear, _viewMonth, 1);
    final daysInMonth = DateTime(_viewYear, _viewMonth + 1, 0).day;
    final lead = firstDay.weekday - 1; // 周一为 1，网格首列即周一
    final cells = <Widget>[
      for (int i = 0; i < lead; i++) const SizedBox.shrink(),
      for (int d = 1; d <= daysInMonth; d++)
        _buildDayCell(DateTime(_viewYear, _viewMonth, d)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => _shiftMonth(-1),
              icon: const Icon(Icons.chevron_left),
              visualDensity: VisualDensity.compact,
              tooltip: '上一月',
            ),
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _yearMode = true),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('$_viewYear年$_viewMonth月',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      const Icon(Icons.expand_more,
                          size: 18, color: AppTheme.textSub),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: () => _shiftMonth(1),
              icon: const Icon(Icons.chevron_right),
              visualDensity: VisualDensity.compact,
              tooltip: '下一月',
            ),
          ],
        ),
        Row(
          children: [
            for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Text(w,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSub)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1.15,
          children: cells,
        ),
      ],
    );
  }

  Widget _buildDayCell(DateTime d) {
    final disabled = d.isBefore(_minDay) || d.isAfter(_maxDay);
    final isStart = d == _start;
    final isEnd = d == _end;
    final inRange = _inRange(d);
    final isEdge = isStart || isEnd;

    Color bg = Colors.transparent;
    Color fg = AppTheme.textMain;
    if (disabled) {
      fg = AppTheme.textSub.withValues(alpha: 0.4);
    } else if (isEdge) {
      bg = AppTheme.primary;
      fg = Colors.white;
    } else if (inRange) {
      bg = AppTheme.primary.withValues(alpha: 0.12);
      fg = AppTheme.primary;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: disabled ? null : () => _onDayTap(d),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          '${d.day}',
          style: TextStyle(
            fontSize: 13,
            color: fg,
            fontWeight: isEdge ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
