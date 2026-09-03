import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

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
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? '新建客户' : '编辑客户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '客户名称 *', hintText: '如：李明工作室')),
            const SizedBox(height: 12),
            TextField(controller: contactCtrl, decoration: const InputDecoration(labelText: '联系方式', hintText: '微信 / 手机号')),
            const SizedBox(height: 12),
            TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注', hintText: '偏好、价格敏感度等')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        await AppDb.instance.updateCustomer(
          c.copyWith(
            name: nameCtrl.text.trim(),
            contact: contactCtrl.text.trim(),
            note: noteCtrl.text.trim(),
          ),
        );
      }
      await _load();
    }
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
        actions: [
          IconButton(
            tooltip: '新建客户',
            icon: const Icon(Icons.add),
            onPressed: _addOrEdit,
          ),
        ],
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
                                      leading: CircleAvatar(
                                        backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                                        foregroundColor: AppTheme.primary,
                                        child: Text(c.name.characters.first,
                                            style: const TextStyle(fontWeight: FontWeight.w600)),
                                      ),
                                      title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                      subtitle: Text(
                                        [c.contact, c.note].where((e) => e.isNotEmpty).join(' · '),
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
          Text('点右上角 + 新建一个吧', style: TextStyle(color: AppTheme.textSub)),
        ],
      ),
    );
  }
}
