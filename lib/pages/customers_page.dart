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
  // 第19批 标签系统：标签池 / 客户->标签映射 / 当前筛选标签
  List<Tag> _allTags = [];
  Map<int, List<Tag>> _tagsByCust = {};
  int? _selectedTagId;

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
    final tags = await AppDb.instance.getTags();
    final map = await AppDb.instance.tagsByCustomers();
    if (!mounted) return;
    setState(() {
      _customers = list;
      _allTags = tags;
      _tagsByCust = map;
      _loading = false;
    });
  }

  List<Customer> get _filtered {
    final q = _query.trim().toLowerCase();
    var result = _customers;
    if (q.isNotEmpty) {
      result = result
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              c.contact.toLowerCase().contains(q) ||
              c.note.toLowerCase().contains(q))
          .toList();
    }
    if (_selectedTagId != null) {
      result = result
          .where((c) => (_tagsByCust[c.id] ?? const <Tag>[])
              .any((t) => t.id == _selectedTagId))
          .toList();
    }
    return result;
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

  // ---- 第19批 标签系统：列表页标签能力 ----
  List<Tag> _tagsOf(Customer c) => _tagsByCust[c.id] ?? const <Tag>[];

  // 顶部标签筛选条（横向 chips）：全部 + 各标签，点击切换按标签筛选客户。
  Widget _buildTagFilterBar() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 6),
            child: ChoiceChip(
              label: Text(_selectedTagId == null ? '全部' : '全部标签'),
              selected: _selectedTagId == null,
              onSelected: (_) => setState(() => _selectedTagId = null),
              selectedColor: AppTheme.primary,
              labelStyle: TextStyle(
                fontSize: 12,
                color: _selectedTagId == null
                    ? Colors.white
                    : AppTheme.textSub,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
          ),
          for (final t in _allTags)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 6),
              child: ChoiceChip(
                key: ValueKey('tag_filter_${t.id}'),
                label: Text(t.name),
                selected: _selectedTagId == t.id,
                onSelected: (_) => setState(() => _selectedTagId = t.id),
                selectedColor: Color(t.color).withValues(alpha: 0.18),
                checkmarkColor: Color(t.color),
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: _selectedTagId == t.id
                      ? Color(t.color)
                      : AppTheme.textSub,
                  fontWeight: FontWeight.w600,
                ),
                side: BorderSide(
                    color: Color(t.color).withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),
        ],
      ),
    );
  }

  // 标签池管理入口（编辑/删除标签 + 标签维度汇总），返回后刷新标签与映射。
  Future<void> _openTagManagePage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _TagManagePage()),
    );
    await _load();
  }

  // 卡片标签 chip（彩色）：最多展示 2 个，超出折叠为 +n。
  Widget _buildCardTagChips(Customer c) {
    final tags = _tagsOf(c);
    if (tags.isEmpty) return const SizedBox.shrink();
    final shown = tags.take(2).toList();
    final remain = tags.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final t in shown)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _TagChip(tag: t),
          ),
        if (remain > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('+$remain',
                style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSub,
                    fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final customers = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('客户'),
        actions: [
          IconButton(
            tooltip: '标签池',
            icon: const Icon(Icons.sell_outlined),
            onPressed: _openTagManagePage,
          ),
        ],
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
                _buildTagFilterBar(),
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
                                          _buildCardTagChips(c),
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
  List<Tag> _tags = []; // 当前客户已打标签（第19批 标签系统）

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final projs =
        await AppDb.instance.getProjectsByCustomer(widget.customer.id!);
    final paid = await AppDb.instance.customerPaidTotal(widget.customer.id!);
    final tags = await AppDb.instance.getCustomerTags(widget.customer.id!);
    if (!mounted) return;
    setState(() {
      _projects = projs;
      _paidTotal = paid;
      _tags = tags;
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
                _buildTagCard(),
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

  // ---- 第19批 标签系统：详情页标签展示卡 ----
  Widget _buildTagCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.sell_outlined, size: 20, color: AppTheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('标签',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  if (_tags.isEmpty)
                    const Text('未打标签',
                        style: TextStyle(color: AppTheme.textSub, fontSize: 13))
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in _tags) _TagChip(tag: t),
                      ],
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: _editTags,
              child: const Text('管理'),
            ),
          ],
        ),
      ),
    );
  }

  // 标签管理：底部弹出全标签勾选区，支持新建自定义标签（含选色）。
  Future<void> _editTags() async {
    final all = await AppDb.instance.getTags();
    if (!mounted) return;
    final sel = <int>{for (final t in _tags) t.id!};
    final tags = [...all];
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void commit() {
            AppDb.instance
                .setCustomerTags(widget.customer.id!, sel.toList())
                .then((_) => setSheet(() {}));
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('标签管理',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text('已选 ${sel.length}',
                          style: const TextStyle(color: AppTheme.textSub)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('选择标签为「${widget.customer.name}」打标，可多选',
                      style: const TextStyle(
                          color: AppTheme.textSub, fontSize: 12)),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in tags)
                            FilterChip(
                              label: Text(t.name),
                              selected: sel.contains(t.id),
                              onSelected: (v) {
                                setSheet(() {
                                  if (v) {
                                    sel.add(t.id!);
                                  } else {
                                    sel.remove(t.id!);
                                  }
                                  commit();
                                });
                              },
                              selectedColor:
                                  Color(t.color).withValues(alpha: 0.18),
                              checkmarkColor: Color(t.color),
                              labelStyle: TextStyle(
                                  color: Color(t.color),
                                  fontWeight: sel.contains(t.id)
                                      ? FontWeight.w600
                                      : FontWeight.w400),
                              side: BorderSide(
                                  color: Color(t.color).withValues(alpha: 0.4)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20)),
                            ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final t = await _createTagDialog();
                              if (t != null) {
                                setSheet(() {
                                  tags.add(t);
                                  sel.add(t.id!);
                                  commit();
                                });
                              }
                            },
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('新建标签'),
                            style: OutlinedButton.styleFrom(
                                shape: const StadiumBorder()),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              final changed = await _openTagManagePage();
                              if (ctx.mounted && changed == true) {
                                Navigator.pop(ctx, true);
                              }
                            },
                            icon: const Icon(Icons.tune, size: 16),
                            label: const Text('标签池管理'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (saved == true) {
      await _load();
    }
  }

  // 新建标签对话框：名称 + 色板单选。
  Future<Tag?> _createTagDialog({Tag? edit}) async {
    final nameCtrl = TextEditingController(text: edit?.name ?? '');
    const palette = <int>[
      0xFFE53935, 0xFFFB8C00, 0xFFFDD835, 0xFF43A047,
      0xFF00897B, 0xFF1E88E5, 0xFF8E24AA, 0xFF546E7A,
    ];
    var picked = edit?.color ?? palette.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(edit == null ? '新建标签' : '编辑标签'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                maxLength: 8,
                decoration: const InputDecoration(
                    labelText: '标签名称', hintText: '如：VIP 客户'),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in palette)
                    GestureDetector(
                      onTap: () => setDlg(() => picked = c),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: picked == c
                              ? Border.all(color: Colors.black54, width: 2.5)
                              : null,
                        ),
                        child: picked == c
                            ? const Icon(Icons.check, size: 18, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ],
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
    if (ok == true) return Tag(name: nameCtrl.text.trim(), color: picked);
    return null;
  }

  // 标签池管理（编辑/删除标签），返回是否发生变更。
  Future<bool?> _openTagManagePage() {
    return Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _TagManagePage()),
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

// ================= 第19批 标签系统：彩色标签 chip（列表与详情共用）=================
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag});

  final Tag tag;

  @override
  Widget build(BuildContext context) {
    final c = Color(tag.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(tag.name,
              style: TextStyle(
                  fontSize: 11, color: c, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ================= 第19批 标签系统：标签池管理（含标签维度汇总）=================
class _TagManagePage extends StatefulWidget {
  const _TagManagePage();

  @override
  State<_TagManagePage> createState() => _TagManagePageState();
}

class _TagManagePageState extends State<_TagManagePage> {
  static final NumberFormat _fmt = NumberFormat('#,##0.00');

  List<Map<String, Object?>> _summaries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AppDb.instance.tagSummaries();
    if (!mounted) return;
    setState(() {
      _summaries = s;
      _loading = false;
    });
  }

  // 新建 / 编辑标签（名称 + 色板），返回 Tag 或 null。
  Future<Tag?> _openEditor({Tag? edit}) async {
    final nameCtrl = TextEditingController(text: edit?.name ?? '');
    const palette = <int>[
      0xFFE53935, 0xFFFB8C00, 0xFFFDD835, 0xFF43A047,
      0xFF00897B, 0xFF1E88E5, 0xFF8E24AA, 0xFF546E7A,
    ];
    var picked = edit?.color ?? palette.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(edit == null ? '新建标签' : '编辑标签'),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                maxLength: 8,
                decoration: const InputDecoration(
                    labelText: '标签名称', hintText: '如：VIP 客户'),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in palette)
                    GestureDetector(
                      onTap: () => setDlg(() => picked = c),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: picked == c
                              ? Border.all(color: Colors.black54, width: 2.5)
                              : null,
                        ),
                        child: picked == c
                            ? const Icon(Icons.check,
                                size: 18, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ],
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
    if (ok != true) return null;
    if (edit == null) {
      return Tag(name: nameCtrl.text.trim(), color: picked);
    }
    return edit.copyWith(name: nameCtrl.text.trim(), color: picked);
  }

  Future<void> _create() async {
    final t = await _openEditor();
    if (t != null) {
      await AppDb.instance.insertTag(t.name, t.color);
      await _load();
    }
  }

  Future<void> _edit(Map<String, Object?> s) async {
    final tag = Tag(
      id: s['tag_id'] as int?,
      name: (s['tag_name'] as String?) ?? '',
      color: (s['tag_color'] as num?)?.toInt() ?? 0xFF4C9AFF,
    );
    final updated = await _openEditor(edit: tag);
    if (updated != null) {
      await AppDb.instance.updateTag(updated);
      await _load();
    }
  }

  Future<void> _remove(Map<String, Object?> s) async {
    final id = s['tag_id'] as int?;
    final name = s['tag_name'] as String? ?? '';
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确定删除标签「$name」吗？\n该标签与全部客户的关联将一并移除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteTag(id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('标签池')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('新建标签'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _summaries.isEmpty
              ? const Center(
                  child: Text('还没有标签，点右下角新建',
                      style: TextStyle(color: AppTheme.textSub)))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    Container(
                      color: AppTheme.primary.withValues(alpha: 0.06),
                      padding: const EdgeInsets.all(12),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: AppTheme.primary),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '标签维度汇总：每行显示该标签下的客户数与该批客户累计收款，'
                              '仅做轻量统计，不联动对账流水。',
                              style: TextStyle(
                                  fontSize: 12, color: AppTheme.textSub),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final s in _summaries)
                      Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: Color(
                                  (s['tag_color'] as num?)?.toInt() ??
                                      0xFF4C9AFF),
                              shape: BoxShape.circle,
                            ),
                          ),
                          title: Text(
                            (s['tag_name'] as String?) ?? '',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${s['customer_count'] ?? 0} 位客户 · '
                            '累计收款 ¥${_fmt.format(((s['paid_total'] as num?)?.toInt() ?? 0) / 100)}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined,
                                    size: 20),
                                onPressed: () => _edit(s),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20, color: AppTheme.danger),
                                onPressed: () => _remove(s),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
