import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../theme.dart';
import 'paywall_page.dart';

/// 对账页（v1.10.0 项目维度汇总 + 第17批 v1.28.0 收款流水明细）：
/// 上方保留每个项目 约定总额 / 已收 / 待收 汇总；
/// 下方新增「收款流水」明细列表，支持 全部/未对账/已对账 筛选、
/// 单笔切换对账标记、展示关联报价（quote_id 精确联动）。
/// 数据均来自本机 SQLite，不涉及云端。
class ReconciliationPage extends StatefulWidget {
  const ReconciliationPage({super.key});

  @override
  State<ReconciliationPage> createState() => _ReconciliationPageState();
}

class _ReconciliationPageState extends State<ReconciliationPage> {
  bool _loading = true;
  List<Map<String, Object?>> _rows = [];
  List<Map<String, Object?>> _flows = [];
  int _flowFilter = 0; // 0=全部 1=未对账 2=已对账
  final _fmt = NumberFormat('#,##0.00');
  final _dateFmt = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool? _filterValue(int f) =>
      f == 1 ? true : (f == 2 ? false : null);

  Future<void> _load() async {
    final rows = await AppDb.instance.reconciliationSummary();
    final flows = await AppDb.instance
        .reconciliationFlows(reconciled: _filterValue(_flowFilter));
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _flows = flows;
      _loading = false;
    });
  }

  Future<void> _setFilter(int f) async {
    setState(() {
      _flowFilter = f;
      _loading = true;
    });
    final flows = await AppDb.instance
        .reconciliationFlows(reconciled: _filterValue(f));
    if (!mounted) return;
    setState(() {
      _flows = flows;
      _loading = false;
    });
  }

  Future<void> _toggleFlow(Map<String, Object?> flow) async {
    final id = (flow['id'] as num?)?.toInt() ?? 0;
    final cur = ((flow['reconciled'] as num?)?.toInt() ?? 0) == 1;
    await AppDb.instance.setPaymentReconciled(id, !cur);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(!cur ? '已标记为已对账' : '已取消对账标记')));
  }

  int _v(Object? v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    // 第15批：经营对账汇总加 VIP 门禁，不隐藏入口，免费用户进入即见升级引导。
    if (!AppState.instance.isPro) {
      return _vipGate(
        context,
        appBarTitle: '对账汇总',
        feature: '经营对账汇总',
        desc: '多维度经营对账报表为专业版专属权益。',
      );
    }
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
                  const SizedBox(height: 14),
                  _buildFlowsSection(),
                ],
              ),
            ),
    );
  }

  // 第17批：收款流水明细区块（筛选 + 列表 + 对账标记）
  Widget _buildFlowsSection() {
    final unRec =
        _flows.where((f) => ((f['reconciled'] as num?)?.toInt() ?? 0) != 1).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              const Text('收款流水',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _flowFilter == 0
                      ? '共 ${_flows.length} 笔，其中未对账 $unRec 笔'
                      : (_flowFilter == 1
                          ? '未对账 $unRec 笔'
                          : '已对账 ${_flows.length - unRec} 笔'),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _FilterChip(
                label: '全部',
                selected: _flowFilter == 0,
                onTap: () => _setFilter(0),
              ),
              const SizedBox(width: 10),
              _FilterChip(
                label: '未对账',
                selected: _flowFilter == 1,
                color: AppTheme.warn,
                onTap: () => _setFilter(1),
              ),
              const SizedBox(width: 10),
              _FilterChip(
                label: '已对账',
                selected: _flowFilter == 2,
                color: AppTheme.accent,
                onTap: () => _setFilter(2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_flows.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text('暂无收款流水，登记收款后在此对账',
                style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
          )
        else
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (int i = 0; i < _flows.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 14, endIndent: 14),
                  _FlowRow(
                    flow: _flows[i],
                    fmt: _fmt,
                    dateFmt: _dateFmt,
                    onToggle: () => _toggleFlow(_flows[i]),
                  ),
                ],
              ],
            ),
          ),
      ],
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

// 第17批：收款流水筛选 chip
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color color;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color = AppTheme.primary,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: color.withValues(alpha: 0.15),
      labelStyle: TextStyle(
        fontSize: 12,
        color: selected ? color : AppTheme.textMain,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

// 第17批：收款流水单行（金额 / 类型 / 项目 / 日期 / 关联报价 / 对账标记与切换）
class _FlowRow extends StatelessWidget {
  final Map<String, Object?> flow;
  final NumberFormat fmt;
  final DateFormat dateFmt;
  final VoidCallback onToggle;
  const _FlowRow({
    required this.flow,
    required this.fmt,
    required this.dateFmt,
    required this.onToggle,
  });

  int _v(Object? v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final amount = _v(flow['amount']);
    final reconciled = ((flow['reconciled'] as num?)?.toInt() ?? 0) == 1;
    final t = _v(flow['type']);
    final typeLabel = (flow['type_label'] as String?)?.trim() ?? '';
    final typeName = typeLabel.isNotEmpty
        ? typeLabel
        : (t >= 0 && t < PayType.values.length
            ? PayType.values[t].label
            : '收款');
    final project = (flow['project_title'] as String?)?.trim() ?? '已删除项目';
    final quote = (flow['quote_title'] as String?)?.trim() ?? '';
    final note = (flow['note'] as String?)?.trim() ?? '';
    final paidAt = DateTime.fromMillisecondsSinceEpoch(_v(flow['paid_at']));
    final subLine = [
      dateFmt.format(paidAt),
      if (quote.isNotEmpty) '报价·$quote',
      if (note.isNotEmpty) note,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('+${fmt.format(amount / 100)}',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accent)),
                    const SizedBox(width: 8),
                    Text(typeName,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSub)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(project,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMain)),
                const SizedBox(height: 2),
                Text(subLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSub)),
              ],
            ),
          ),
          _Tag(
            text: reconciled ? '已对账' : '未对账',
            color: reconciled ? AppTheme.accent : AppTheme.warn,
          ),
          IconButton(
            tooltip: reconciled ? '取消对账标记' : '标记已对账',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              reconciled ? Icons.undo : Icons.check_circle_outline,
              size: 20,
              color: reconciled ? AppTheme.textSub : AppTheme.primary,
            ),
            onPressed: onToggle,
          ),
        ],
      ),
    );
  }
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
