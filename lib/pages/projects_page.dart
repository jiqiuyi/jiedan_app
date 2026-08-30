import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../database.dart';
import '../models.dart';
import '../constants.dart';
import '../app_state.dart';
import '../theme.dart';
import '../state/ticker.dart';
import 'project_detail_page.dart';
import 'paywall_page.dart';
import '../widgets/payment_dialog.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  List<Project> _projects = [];
  List<Customer> _customers = [];
  Map<int, double> _paidTotals = {};
  int _tab = 0; // 0=全部, 1..4=状态+1
  String _query = '';
  Timer? _debounce;
  bool _loading = true;

  final _tabs = ['全部', '接单', '制作中', '待收尾款', '完结'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final db = AppDb.instance;
    final projects = await db.getProjects();
    final customers = await db.getCustomers();
    final paidTotals = await db.projectPaidTotals();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _customers = customers;
      _paidTotals = paidTotals;
      _loading = false;
    });
  }

  List<Project> get _filtered {
    var list = _projects;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((e) =>
              e.title.toLowerCase().contains(q) ||
              _customerName(e.customerId).toLowerCase().contains(q))
          .toList();
    }
    if (_tab != 0) {
      final s = ProjectStatus.values[_tab - 1];
      list = list.where((e) => e.status == s).toList();
    }
    return list;
  }

  String _customerName(int id) {
    final c = _customers.where((e) => e.id == id).firstOrNull;
    return c?.name ?? '未知客户';
  }

  Future<void> _addProject() async {
    if (!AppState.instance.isPro &&
        _projects.where((e) => e.status != ProjectStatus.done).length >=
            AppConfig.freeProjectLimit) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => PaywallPage(
          title: '免费版最多管理 ${AppConfig.freeProjectLimit} 个进行中的项目',
          desc: '解锁后项目数量不再受限，适合同时接多个单的你',
        ),
      ));
      return;
    }
    final customers = await AppDb.instance.getCustomers();
    if (!mounted) return;
    if (customers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在「客户」页新建一个客户')),
      );
      return;
    }
    if (customers.length != _customers.length) {
      setState(() => _customers = customers);
    }
    final titleCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    int selectedCustomer = customers.first.id!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('新建项目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: '项目名称 *', hintText: '如：品牌官网改版')),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: selectedCustomer,
                decoration: const InputDecoration(labelText: '所属客户'),
                items: customers.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                onChanged: (v) => setDlg(() => selectedCustomer = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(labelText: '约定总额（元）', hintText: '0.00'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () => titleCtrl.text.trim().isEmpty
                  ? null
                  : Navigator.pop(ctx, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await AppDb.instance.insertProject(Project(
        customerId: selectedCustomer,
        title: titleCtrl.text.trim(),
        status: ProjectStatus.accepted,
        amountTotal: double.tryParse(amountCtrl.text.trim()) ?? 0,
        createdAt: now,
        updatedAt: now,
      ));
      Ticker.ping();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('项目')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: _addProject,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              onChanged: (v) {
                // 200ms 防抖
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 200), () {
                  if (mounted) setState(() => _query = v);
                });
              },
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '搜索项目名称 / 客户',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: AppTheme.textSub.withValues(alpha: 0.05),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (ctx, i) {
                final selected = _tab == i;
                return ChoiceChip(
                  label: Text(_tabs[i]),
                  selected: selected,
                  onSelected: (_) => setState(() => _tab = i),
                  selectedColor: AppTheme.primary.withValues(alpha: 0.12),
                  labelStyle: TextStyle(
                    color: selected ? AppTheme.primary : AppTheme.textSub,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(
                        child: Text(
                          _projects.isEmpty || _query.trim().isNotEmpty
                              ? '没有匹配的项目'
                              : '这里空空如也，点右下角 + 新建项目',
                          style: const TextStyle(color: AppTheme.textSub),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 90),
                        itemCount: items.length,
                        // 大列表优化：固定行高减少 layout 开销
                        itemExtent: 104,
                        itemBuilder: (ctx, i) {
                          final pr = items[i];
                          final paid = _paidTotals[pr.id] ?? 0;
                          final remaining = (pr.amountTotal - paid).clamp(0, double.infinity);
                          return Card(
                            child: ListTile(
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => ProjectDetailPage(project: pr, customerName: _customerName(pr.customerId))),
                                );
                                await _load();
                              },
                              title: Text(pr.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${_customerName(pr.customerId)} · 约定 ¥${NumberFormat('#,##0.00').format(pr.amountTotal)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: AppTheme.textSub)),
                                  const SizedBox(height: 4),
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        const TextSpan(text: '已收 ', style: TextStyle(color: AppTheme.textSub)),
                                        TextSpan(
                                          text: '¥${NumberFormat('#,##0.00').format(paid)}',
                                          style: TextStyle(
                                              color: AppTheme.accent,
                                              fontWeight: FontWeight.w700),
                                        ),
                                        const TextSpan(text: '　待收 ', style: TextStyle(color: AppTheme.textSub)),
                                        TextSpan(
                                          text: remaining <= 0
                                              ? '已结清'
                                              : '¥${NumberFormat('#,##0.00').format(remaining)}',
                                          style: TextStyle(
                                              color: remaining <= 0 ? AppTheme.accent : AppTheme.warn,
                                              fontWeight: FontWeight.w700),
                                        ),
                                      ],
                                    ),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                              isThreeLine: true,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.payments_outlined, size: 22),
                                    color: AppTheme.primary,
                                    tooltip: '登记收款',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () async {
                                      final ok = await showPaymentDialog(
                                        context,
                                        projectId: pr.id!,
                                        amountTotal: pr.amountTotal,
                                        paidTotal: paid,
                                      );
                                      if (ok) await _load();
                                    },
                                  ),
                                  _StatusBadge(status: pr.status),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final ProjectStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final map = {
      ProjectStatus.accepted: (AppTheme.primary, Icons.mark_email_read_outlined),
      ProjectStatus.working: (AppTheme.accent, Icons.build_outlined),
      ProjectStatus.awaiting: (AppTheme.warn, Icons.schedule),
      ProjectStatus.done: (AppTheme.textSub, Icons.check_circle_outline),
    };
    final (color, icon) = map[status]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(status.label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
