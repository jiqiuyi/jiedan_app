import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../theme.dart';
import 'paywall_page.dart';
import '../widgets/app_ui.dart';

/// 对账页（v1.10.0 项目维度汇总 + 第17批 v1.28.0 收款流水明细）：
/// 上方保留每个项目 约定总额 / 已收 / 待收 汇总；
/// 下方新增「收款流水」明细列表，支持 全部/未对账/已对账 筛选、
/// 单笔切换对账标记、展示关联报价（quote_id 精确联动）。
/// 数据均来自本机 SQLite，不涉及云端。
class ReconciliationPage extends StatefulWidget {
const   ReconciliationPage({super.key});

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
        content: Text(!cur ? L10n.instance.t('reconcile_marked') : L10n.instance.t('reconcile_unmarked'))));
  }

  int _v(Object? v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    // 第15批：经营对账汇总加 VIP 门禁，不隐藏入口，免费用户进入即见升级引导。
    if (!AppState.instance.isPro) {
      return _vipGate(
        context,
        appBarTitle: L10n.instance.t('reconciliation_page_reconciliation'),
        feature: L10n.instance.t('i18n_534'),
        desc: L10n.instance.t('i18n_204'),
      );
    }
    final totalAgreed = _rows.fold<int>(0, (s, r) => s + _v(r['amount_total']));
    final totalPaid = _rows.fold<int>(0, (s, r) => s + _v(r['paid_total']));
    final totalPending = _rows.fold<int>(0, (s, r) => s + _v(r['pending_total']));
    final cleared = _rows
        .where((r) => _v(r['pending_total']) <= 0)
        .length;

    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('reconcile_title'))),
      body: _loading
          ? AppLoading()
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
                  SizedBox(height: 6),
                  if (_rows.isEmpty)
                    Card(
                      child: AppEmpty(
                        icon: Icons.assessment_outlined,
                        title: L10n.instance.t('reconcile_no_data'),
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
                  SizedBox(height: 14),
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
              Text(L10n.instance.t('reconcile_flow'),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  _flowFilter == 0
                      ? L10n.instance.t('i18n_129', args: {'v0':'${_flows.length}', 'v1':'$unRec'})
                      : (_flowFilter == 1
                          ? L10n.instance.t('i18n_438', args: {'v0':'$unRec'})
                          : L10n.instance.t('i18n_266', args: {'v0':'${_flows.length - unRec}'})),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
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
                label: L10n.instance.t('common_all'),
                selected: _flowFilter == 0,
                onTap: () => _setFilter(0),
              ),
              SizedBox(width: 10),
              _FilterChip(
                label: L10n.instance.t('reconcile_unreconciled'),
                selected: _flowFilter == 1,
                color: AppTheme.warn,
                onTap: () => _setFilter(1),
              ),
              SizedBox(width: 10),
              _FilterChip(
                label: L10n.instance.t('reconcile_reconciled'),
                selected: _flowFilter == 2,
                color: AppTheme.accent,
                onTap: () => _setFilter(2),
              ),
            ],
          ),
        ),
        SizedBox(height: 8),
        if (_flows.isEmpty)
          AppEmpty(
            icon: Icons.receipt_long_outlined,
            title: L10n.instance.t('reconcile_empty'),
          )
        else
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                for (int i = 0; i < _flows.length; i++) ...[
                  if (i > 0)
                    AppCardDivider(),
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
        if (index > 0) AppCardDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? L10n.instance.t('i18n_639') : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  if (pending <= 0)
                    _Tag(text: L10n.instance.t('reconcile_settled'), color: AppTheme.accent)
                  else
                    _Tag(text: L10n.instance.t('reconcile_pending'), color: AppTheme.warn),
                ],
              ),
              if (customer.isNotEmpty)
                Text(customer,
                    style: TextStyle(
                        color: AppTheme.textSub, fontSize: 12)),
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _Item(
                        label: L10n.instance.t('reconcile_agreed'),
                        value: '¥${_fmt.format(agreed / 100)}',
                        color: AppTheme.textMain),
                  ),
                  Expanded(
                    child: _Item(
                        label: L10n.instance.t('project_received'),
                        value: '¥${_fmt.format(paid / 100)}',
                        color: AppTheme.accent),
                  ),
                  Expanded(
                    child: _Item(
                        label: L10n.instance.t('project_pending'),
                        value: '¥${_fmt.format(pending / 100)}',
                        color: AppTheme.warn),
                  ),
                ],
              ),
              SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xxs),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                  color: AppTheme.primary,
                ),
              ),
              SizedBox(height: 4),
              Text(L10n.instance.t('reconcile_progress_line', args: {'(ratio * 100).toStringAsFixed(0)': (ratio * 100).toStringAsFixed(0)}),
                  style: TextStyle(
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
        borderRadius: BorderRadius.circular(AppRadius.xs),
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
            style: TextStyle(fontSize: 11, color: AppTheme.textSub)),
        SizedBox(height: 2),
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
            Text(L10n.instance.t('reconcile_summary'),
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SumItem(
                      label: L10n.instance.t('project_agreed_total'),
                      value: '¥${fmt.format(totalAgreed / 100)}'),
                ),
                Expanded(
                  child: _SumItem(
                      label: L10n.instance.t('reconcile_total_received'),
                      value: '¥${fmt.format(totalPaid / 100)}',
                      color: AppTheme.accent),
                ),
                Expanded(
                  child: _SumItem(
                      label: L10n.instance.t('reconcile_total_pending'),
                      value: '¥${fmt.format(totalPending / 100)}',
                      color: AppTheme.warn),
                ),
              ],
            ),
            SizedBox(height: 10),
            Text(L10n.instance.t('reconcile_summary_line', args: {'all':'$all', 'cleared':'$cleared'}),
                style: TextStyle(
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
            style: TextStyle(fontSize: 11, color: AppTheme.textSub)),
        SizedBox(height: 2),
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
    return AppFilterChip(
      label: label,
      selected: selected,
      color: color,
      onTap: onTap,
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
            : L10n.instance.t('reconciliation_page_collect'));
    final project = (flow['project_title'] as String?)?.trim() ?? '';
    final quote = (flow['quote_title'] as String?)?.trim() ?? '';
    final note = (flow['note'] as String?)?.trim() ?? '';
    final paidAt = DateTime.fromMillisecondsSinceEpoch(_v(flow['paid_at']));
    final subLine = [
      dateFmt.format(paidAt),
      if (quote.isNotEmpty) L10n.instance.t('i18n_346', args: {'v0': quote}),
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
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accent)),
                    SizedBox(width: 8),
                    Text(typeName,
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSub)),
                  ],
                ),
                SizedBox(height: 2),
                Text(project.isEmpty ? L10n.instance.t('common_deleted_project') : project,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textMain)),
                SizedBox(height: 2),
                Text(subLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.textSub)),
              ],
            ),
          ),
          _Tag(
            text: reconciled ? L10n.instance.t('reconcile_reconciled') : L10n.instance.t('reconcile_unreconciled'),
            color: reconciled ? AppTheme.accent : AppTheme.warn,
          ),
          IconButton(
            tooltip: reconciled ? L10n.instance.t('reconcile_unmark') : L10n.instance.t('reconcile_mark'),
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
