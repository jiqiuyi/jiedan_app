import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../widgets/slidable_action.dart';
import '../database.dart';
import '../app_state.dart';
import '../constants.dart';
import '../state/ticker.dart';
import '../theme.dart';
import 'paywall_page.dart';

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key});

  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  List<Customer> _customers = [];
  bool _loading = true;
  String _query = '';
  Timer? _debounce;
  // 订阅全局数据变更广播（删除/编辑来自本页或项目详情页级联），自动刷新。
  StreamSubscription<int>? _tickerSub;

  @override
  void initState() {
    super.initState();
    _tickerSub = Ticker.counterStream.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tickerSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await AppDb.instance.getCustomers();
    if (!mounted) return;
    setState(() {
      _customers = list;
      _loading = false;
    });
  }

  List<Customer> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _customers;
    return _customers
        .where((c) =>
            c.name.toLowerCase().contains(q) ||
            c.contact.toLowerCase().contains(q) ||
            c.note.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _addOrEdit([Customer? c]) async {
    // 免费版额度校验
    if (!AppState.instance.isPro &&
        c == null &&
        _customers.length >= AppConfig.freeCustomerLimit) {
      _openPaywall(
        '免费版最多管理 ${AppConfig.freeCustomerLimit} 个客户',
        '解锁后无限客户，畅用一个客户的也够了，但多个客户更重要',
      );
      return;
    }
    final nameCtrl = TextEditingController(text: c?.name ?? '');
    final contactCtrl = TextEditingController(text: c?.contact ?? '');
    final noteCtrl = TextEditingController(text: c?.note ?? '');
    final industryCtrl = TextEditingController(text: c?.industry ?? '');
    final sourceCtrl = TextEditingController(text: c?.source ?? '');
    final locationCtrl = TextEditingController(text: c?.location ?? '');
    var newLastContactAt = c?.lastContactAt ?? 0;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? '新建客户' : '编辑客户'),
        content: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (ctx, setDlgState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: '客户名称 *', hintText: '如：李明工作室')),
                const SizedBox(height: 10),
                TextField(
                    controller: contactCtrl,
                    decoration: const InputDecoration(
                        labelText: '联系方式', hintText: '微信 / 手机号')),
                const SizedBox(height: 10),
                TextField(
                    controller: industryCtrl,
                    decoration: const InputDecoration(
                        labelText: '行业', hintText: '如：餐饮、电商、装修')),
                const SizedBox(height: 10),
                TextField(
                    controller: sourceCtrl,
                    decoration: const InputDecoration(
                        labelText: '客户来源', hintText: '如：朋友介绍、小红书、老客')),
                const SizedBox(height: 10),
                TextField(
                    controller: locationCtrl,
                    decoration: const InputDecoration(
                        labelText: '所在地', hintText: '如：杭州')),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () async {
                    final now = DateTime.now();
                    final base = newLastContactAt > 0
                        ? DateTime.fromMillisecondsSinceEpoch(newLastContactAt)
                        : now;
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate:
                          DateTime(base.year, base.month, base.day),
                      firstDate: DateTime(2020),
                      lastDate: now,
                    );
                    if (d != null) {
                      setDlgState(() => newLastContactAt = DateTime(
                              d.year, d.month, d.day)
                          .millisecondsSinceEpoch);
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '最近联系时间',
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.event_outlined,
                            size: 18, color: AppTheme.textSub),
                        const SizedBox(width: 8),
                        Text(newLastContactAt > 0
                            ? _fmtDate(newLastContactAt)
                            : '未设置'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                    controller: noteCtrl,
                    decoration: const InputDecoration(
                        labelText: '备注', hintText: '偏好、价格敏感度等')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => nameCtrl.text.trim().isEmpty
                ? null
                : Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == true && nameCtrl.text.trim().isNotEmpty) {
      if (c == null) {
        await AppDb.instance.insertCustomer(Customer(
          name: nameCtrl.text.trim(),
          contact: contactCtrl.text.trim(),
          note: noteCtrl.text.trim(),
          industry: industryCtrl.text.trim(),
          source: sourceCtrl.text.trim(),
          location: locationCtrl.text.trim(),
          lastContactAt: newLastContactAt,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        await AppDb.instance.updateCustomer(
          c.copyWith(
            name: nameCtrl.text.trim(),
            contact: contactCtrl.text.trim(),
            note: noteCtrl.text.trim(),
            industry: industryCtrl.text.trim(),
            source: sourceCtrl.text.trim(),
            location: locationCtrl.text.trim(),
            lastContactAt: newLastContactAt,
          ),
        );
      }
      await _load();
    }
  }

  /// 档案日期展示（yyyy-MM-dd）
  static String _fmtDate(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _remove(Customer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除客户'),
        content: Text(
            '确定删除客户「${c.name}」吗？\n其名下全部项目及收款记录将被一并删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteCustomer(c.id!);
      await _load();
    }
  }

  Future<void> _openDetail(Customer c) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _CustomerDetailPage(customer: c)),
    );
    _load();
  }

  void _openPaywall(String title, String desc) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => PaywallPage(title: title, desc: desc)));
  }

  @override
  Widget build(BuildContext context) {
    final customers = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('客户'),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新建客户',
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: _addOrEdit,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                      hintText: '搜索客户名称 / 联系方式 / 备注',
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
                Expanded(
                  child: _customers.isEmpty
                      ? const _Empty()
                      : customers.isEmpty
                          ? const Center(child: Text('没有匹配的客户', style: TextStyle(color: AppTheme.textSub)))
                          : ListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 80),
                              itemCount: customers.length,
                              // 卡片高度随内容自适应，保证左滑操作区与卡片严格等高
                              itemBuilder: (ctx, i) {
                                final c = customers[i];
                                return Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Slidable(
                                    key: ValueKey('cust_${c.id}'),
                                  endActionPane: ActionPane(
                                    motion: const ScrollMotion(),
                                    extentRatio: 0.34,
                                    children: [
                                      CustomSlidableAction(
                                        onPressed: (_) => _addOrEdit(c),
                                        backgroundColor: AppTheme.primary,
                                        foregroundColor: Colors.white,
                                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                                        child: const SlidableActionContent(icon: Icons.edit_outlined, label: '编辑'),
                                      ),
                                      CustomSlidableAction(
                                        onPressed: (_) => _remove(c),
                                        backgroundColor: AppTheme.danger,
                                        foregroundColor: Colors.white,
                                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
                                        child: const SlidableActionContent(icon: Icons.delete_outline, label: '删除'),
                                      ),
                                    ],
                                  ),
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    child: ListTile(
                                      onTap: () => _openDetail(c),
                                      leading: CircleAvatar(
                                        backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                                        foregroundColor: AppTheme.primary,
                                        child: Text(c.name.characters.first,
                                            style: const TextStyle(fontWeight: FontWeight.w600)),
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: Text(c.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.w600)),
                                          ),
                                          if (c.industry.isNotEmpty)
                                            Container(
                                              margin: const EdgeInsets.only(left: 6),
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppTheme.primary.withValues(alpha: 0.1),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(c.industry,
                                                  style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600)),
                                            ),
                                        ],
                                      ),
                                      subtitle: Text(
                                        [
                                          c.contact,
                                          c.location,
                                          if (c.lastContactAt > 0)
                                            '最近联系 ${_fmtDate(c.lastContactAt)}',
                                          c.note,
                                        ].where((e) => e.isNotEmpty).join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      ),
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

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_outline, size: 56, color: AppTheme.textSub),
          SizedBox(height: 12),
          Text('还没有客户', style: TextStyle(fontSize: 16, color: AppTheme.textSub)),
          SizedBox(height: 4),
          Text('点右下角 + 新建一个吧', style: TextStyle(color: AppTheme.textSub)),
        ],
      ),
    );
  }
}

// ================= v1.21.0 客户详情：档案字段 + 名下项目与累计收款 =================
class _CustomerDetailPage extends StatefulWidget {
  const _CustomerDetailPage({required this.customer});

  final Customer customer;

  @override
  State<_CustomerDetailPage> createState() => _CustomerDetailPageState();
}

class _CustomerDetailPageState extends State<_CustomerDetailPage> {
  static final NumberFormat _fmt = NumberFormat('#,##0.00');

  List<Project> _projects = [];
  bool _loading = true;
  int _paidTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final projs =
        await AppDb.instance.getProjectsByCustomer(widget.customer.id!);
    final paid = await AppDb.instance.customerPaidTotal(widget.customer.id!);
    if (!mounted) return;
    setState(() {
      _projects = projs;
      _paidTotal = paid;
      _loading = false;
    });
  }

  static String _fmtDate(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.customer;
    return Scaffold(
      appBar: AppBar(title: Text(c.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _infoRow('行业', c.industry),
                _infoRow('客户来源', c.source),
                _infoRow('所在地', c.location),
                _infoRow('联系方式', c.contact),
                _infoRow('最近联系',
                    c.lastContactAt > 0 ? _fmtDate(c.lastContactAt) : '未记录'),
                _infoRow('备注', c.note),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _statCard('项目数', '${_projects.length}',
                          Icons.folder_outlined, AppTheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _statCard(
                          '累计收款',
                          '¥${_fmt.format(_paidTotal / 100)}',
                          Icons.payments_outlined,
                          Colors.green),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('名下项目（${_projects.length}）',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                if (_projects.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('暂无项目',
                          style: TextStyle(color: AppTheme.textSub)),
                    ),
                  )
                else
                  for (final p in _projects)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text(p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                        subtitle:
                            Text('约定金额 ¥${_fmt.format(p.amountTotal / 100)}'),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            p.status.label,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 70,
              child: Text(label,
                  style: const TextStyle(color: AppTheme.textSub))),
          Expanded(child: Text(value.isEmpty ? '—' : value)),
        ],
      ),
    );
  }

  Widget _statCard(String title, String value, IconData icon, Color color) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            Text(title,
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.textSub)),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style:
                      const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}
