import 'dart:async';
import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../widgets/slidable_action.dart';
import '../database.dart';
import '../data/regions.dart';
import '../app_state.dart';
import '../constants.dart';
import '../state/ticker.dart';
import '../theme.dart';
import '../services/error_reporter.dart';
import 'paywall_page.dart';
import '../widgets/app_ui.dart';

class CustomersPage extends StatefulWidget {
const CustomersPage({super.key});

  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  List<Customer> _customers = [];
  bool _loading = true;
  bool _loadFailed = false;
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
    // 三态兜底：DB 异常进入错误态（加载失败+重试），绝不无限转圈。
    try {
      final list = await AppDb.instance.getCustomers();
      final tags = await AppDb.instance.getTags();
      final map = await AppDb.instance.tagsByCustomers();
      if (!mounted) return;
      setState(() {
        _customers = list;
        _allTags = tags;
        _tagsByCust = map;
        _loading = false;
        _loadFailed = false;
      });
    } catch (e, st) {
      ErrorReporter.instance.logError('customers_load', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
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
        L10n.instance.t('i18n_124', args: {'v0':'${AppConfig.freeCustomerLimit}'}),
        L10n.instance.t('i18n_555'),
      );
      return;
    }
    final nameCtrl = TextEditingController(text: c?.name ?? '');
    final contactCtrl = TextEditingController(text: c?.contact ?? '');
    final noteCtrl = TextEditingController(text: c?.note ?? '');
    final industryCtrl = TextEditingController(text: c?.industry ?? '');
    final sourceCtrl = TextEditingController(text: c?.source ?? '');
    final locationCtrl = TextEditingController(text: c?.location ?? '');
    // 省市区级联快捷选择（仅用于回填输入框，输入框仍可自由编辑）
    String? selProvince;
    String? selCity;
    String? selDistrict;
    var manualEdit = false;
    {
      final initParts = (c?.location ?? '')
          .split(RegExp(r'[\s·,，/、]+'))
          .where((e) => e.isNotEmpty)
          .toList();
      if (initParts.isNotEmpty && kRegions.containsKey(initParts[0])) {
        selProvince = initParts[0];
        final cities = regionCities(initParts[0]);
        if (initParts.length > 1 && cities.contains(initParts[1])) {
          selCity = initParts[1];
          final districts = regionDistricts(initParts[0], initParts[1]);
          if (initParts.length > 2 && districts.contains(initParts[2])) {
            selDistrict = initParts[2];
          }
        }
      }
    }
    void syncLocationText() {
      final parts = <String>[
        if (selProvince != null) selProvince!,
        if (selCity != null) selCity!,
        if (selDistrict != null) selDistrict!,
      ];
      if (parts.isEmpty) return;
      locationCtrl.text = parts.join(' ');
      locationCtrl.selection =
          TextSelection.collapsed(offset: locationCtrl.text.length);
    }
    // 行业 / 来源标签下拉：底部弹层选择已维护标签，回填输入框；仍可手动输入。
    Future<void> pickTag(TextEditingController ctrl, String kind,
        String label) async {
      final tags = await AppDb.instance.getTagItems(kind);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheetCtx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  L10n.instance.t('i18n_602', args: {'v0': label}),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMain),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  L10n.instance.t('i18n_089'),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ),
              Flexible(
                child: tags.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          L10n.instance.t('i18n_424'),
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSub),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: tags
                            .map((t) => ListTile(
                                  dense: true,
                                  title: Text(t),
                                  trailing: Icon(Icons.chevron_right,
                                      size: 18, color: AppTheme.textSub),
                                  onTap: () {
                                    ctrl.text = t;
                                    ctrl.selection = TextSelection.collapsed(
                                        offset: ctrl.text.length);
                                    Navigator.pop(sheetCtx);
                                  },
                                ))
                            .toList(),
                      ),
              ),
              SizedBox(height: 8),
            ],
          ),
        ),
      );
    }
    Future<void> pickRegion() async {
      var level = 0;
      if (selProvince != null && selCity != null) {
        level = 2;
      } else if (selProvince != null) {
        level = 1;
      }
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheetCtx) => StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            final List<String> items = switch (level) {
              0 => regionProvinces(),
              1 => regionCities(selProvince!),
              _ => regionDistricts(selProvince!, selCity!),
            };
            final String headTitle = switch (level) {
              0 => L10n.instance.t('i18n_614'),
              1 => L10n.instance.t('i18n_608', args: {'v0':'$selProvince'}),
              _ => L10n.instance.t('i18n_607', args: {'v0':'$selProvince', 'v1':'$selCity'}),
            };
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (level > 0)
                        IconButton(
                          icon: Icon(Icons.arrow_back),
                          tooltip: L10n.instance.t('common_back'),
                          onPressed: () => setSheet(() => level--),
                        )
                      else
                        SizedBox(width: 48),
                      Expanded(
                        child: Text(
                          headTitle,
                          style: TextStyle(
                              fontSize: AppFont.body,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close),
                        tooltip: L10n.instance.t('common_close'),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                  Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        title: Text(items[i]),
                        onTap: () {
                          if (level == 0) {
                            selProvince = items[i];
                            selCity = null;
                            selDistrict = null;
                            setSheet(() => level = 1);
                          } else if (level == 1) {
                            selCity = items[i];
                            selDistrict = null;
                            setSheet(() => level = 2);
                          } else {
                            selDistrict = items[i];
                            syncLocationText();
                            Navigator.pop(sheetCtx);
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }
    var newLastContactAt = c?.lastContactAt ?? 0;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c == null ? L10n.instance.t('customers_new') : L10n.instance.t('customers_edit')),
        content: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (ctx, setDlgState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                        labelText: L10n.instance.t('customers_name_label'), hintText: L10n.instance.t('customers_name_example'))),
                SizedBox(height: 10),
                TextField(
                    controller: contactCtrl,
                    decoration: InputDecoration(
                        labelText: L10n.instance.t('customers_contact_label'), hintText: L10n.instance.t('customers_contact_hint'))),
                SizedBox(height: 10),
                TextField(
                    controller: industryCtrl,
                    onTap: () => pickTag(industryCtrl, 'industry', L10n.instance.t('i18n_552')),
                    decoration: InputDecoration(
                        labelText: L10n.instance.t('i18n_550'),
                        hintText: L10n.instance.t('customers_industry_example'),
                        suffixIcon: Icon(Icons.arrow_drop_down,
                            color: AppTheme.textSub))),
                SizedBox(height: 10),
                TextField(
                    controller: sourceCtrl,
                    onTap: () => pickTag(sourceCtrl, 'source', L10n.instance.t('i18n_459')),
                    decoration: InputDecoration(
                        labelText: L10n.instance.t('i18n_228'),
                        hintText: L10n.instance.t('customers_source_example'),
                        suffixIcon: Icon(Icons.arrow_drop_down,
                            color: AppTheme.textSub))),
                SizedBox(height: 10),
                TextField(
                    controller: locationCtrl,
                    onChanged: (_) => manualEdit = true,
                    onTap: manualEdit ? null : () => pickRegion(),
                    decoration: InputDecoration(
                        labelText: L10n.instance.t('i18n_338'),
                        hintText: L10n.instance.t('customers_region_example'),
                        suffixIcon: IconButton(
                          icon: Icon(Icons.location_on_outlined),
                          tooltip: L10n.instance.t('customers_region_pick'),
                          onPressed: () => pickRegion(),
                        ))),
                SizedBox(height: 4),
                Text(
                  L10n.instance.t('i18n_485'),
                  style: TextStyle(fontSize: AppFont.caption, color: AppTheme.textSub),
                ),
                SizedBox(height: 10),
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
                    decoration: InputDecoration(
                      labelText: L10n.instance.t('i18n_432'),
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.event_outlined,
                            size: 18, color: AppTheme.textSub),
                        SizedBox(width: 8),
                        Text(newLastContactAt > 0
                            ? _fmtDate(newLastContactAt)
                            : L10n.instance.t('i18n_446')),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 4),
                TextField(
                    controller: noteCtrl,
                    decoration: InputDecoration(
                        labelText: L10n.instance.t('common_note'), hintText: L10n.instance.t('customers_notes_hint'))),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
            onPressed: () => nameCtrl.text.trim().isEmpty
                ? null
                : Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_save')),
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
        title: Text(L10n.instance.t('customers_delete')),
        content: Text(
            L10n.instance.t('i18n_502', args: {'v0': c.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
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
              label: Text(_selectedTagId == null ? L10n.instance.t('common_all') : L10n.instance.t('customers_all_tags')),
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
      MaterialPageRoute(builder: (_) => _TagManagePage()),
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
                style: TextStyle(
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
        title: Text(L10n.instance.t('common_customer')),
        actions: [
          IconButton(
            tooltip: L10n.instance.t('customers_tag_pool'),
            icon: Icon(Icons.sell_outlined),
            onPressed: _openTagManagePage,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: L10n.instance.t('customers_new'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        onPressed: _addOrEdit,
        child: Icon(Icons.add),
      ),
      body: _loading
          ? AppLoading()
          : _loadFailed
              ? AppError(
                  title: L10n.instance.t('common_load_failed'),
                  hint: L10n.instance.t('i18n_453'),
                  onRetry: () {
                    setState(() {
                      _loading = true;
                      _loadFailed = false;
                    });
                    _load();
                  },
                )
              : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    onChanged: (v) {
                      // 200ms 防抖
                      _debounce?.cancel();
                      _debounce = Timer(Duration(milliseconds: 200), () {
                        if (mounted) setState(() => _query = v);
                      });
                    },
                    textInputAction: TextInputAction.search,
                    style: TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: L10n.instance.t('customers_search_hint'),
                      prefixIcon: Icon(Icons.search, size: 20),
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.textSub.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                _buildTagFilterBar(),
                Expanded(
                  child: _customers.isEmpty
                      ? _Empty()
                      : customers.isEmpty
                          ? Center(child: Text(L10n.instance.t('customers_no_match'), style: TextStyle(color: AppTheme.textSub)))
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
                                    motion: ScrollMotion(),
                                    extentRatio: 0.34,
                                    children: [
                                      CustomSlidableAction(
                                        onPressed: (_) => _addOrEdit(c),
                                        backgroundColor: AppTheme.primary,
                                        foregroundColor: Colors.white,
                                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(AppRadius.md)),
                                        child: SlidableActionContent(icon: Icons.edit_outlined, label: L10n.instance.t('common_edit')),
                                      ),
                                      CustomSlidableAction(
                                        onPressed: (_) => _remove(c),
                                        backgroundColor: AppTheme.danger,
                                        foregroundColor: Colors.white,
                                        borderRadius: const BorderRadius.horizontal(right: Radius.circular(AppRadius.md)),
                                        child: SlidableActionContent(icon: Icons.delete_outline, label: L10n.instance.t('common_delete')),
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
                                                borderRadius: BorderRadius.circular(AppRadius.xs),
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
                                            L10n.instance.t('i18n_431', args: {'v0': _fmtDate(c.lastContactAt)}),
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
const   _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppEmpty(
            icon: Icons.people_outline,
            title: L10n.instance.t('customers_empty'),
            hint: L10n.instance.t('i18n_487'),
          ),
        ],
      ),
    );
  }
}

// ================= v1.21.0 客户详情：档案字段 + 名下项目与累计收款 =================
class _CustomerDetailPage extends StatefulWidget {
const   _CustomerDetailPage({required this.customer});

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
          ? AppLoading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _infoRow(L10n.instance.t('i18n_550'), c.industry),
                _infoRow(L10n.instance.t('i18n_228'), c.source),
                _infoRow(L10n.instance.t('i18n_338'), c.location),
                _infoRow(L10n.instance.t('i18n_542'), c.contact),
                _infoRow(L10n.instance.t('i18n_430'),
                    c.lastContactAt > 0 ? _fmtDate(c.lastContactAt) : L10n.instance.t('i18n_444')),
                _infoRow(L10n.instance.t('common_note'), c.note),
                SizedBox(height: 16),
                _buildTagCard(),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _statCard(L10n.instance.t('i18n_635'), '${_projects.length}',
                          Icons.folder_outlined, AppTheme.primary),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: _statCard(
                          L10n.instance.t('i18n_527'),
                          '¥${_fmt.format(_paidTotal / 100)}',
                          Icons.payments_outlined,
                          Colors.green),
                    ),
                  ],
                ),
                SizedBox(height: 18),
                Text(L10n.instance.t('i18n_173', args: {'v0':'${_projects.length}'}),
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                SizedBox(height: 4),
                if (_projects.isEmpty)
                  AppEmpty(
                    icon: Icons.folder_open_outlined,
                    title: L10n.instance.t('common_no_projects'),
                  )
                else
                  for (final p in _projects)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text(p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: FontWeight.w600)),
                        subtitle:
                            Text(L10n.instance.t('i18n_533', args: {'v0': _fmt.format(p.amountTotal / 100)})),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(AppRadius.sheet),
                          ),
                          child: Text(
                            p.status.label,
                            style: TextStyle(
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
            Icon(Icons.sell_outlined, size: 20, color: AppTheme.primary),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.instance.t('common_tag'),
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  SizedBox(height: 6),
                  if (_tags.isEmpty)
                    Text(L10n.instance.t('customers_untagged'),
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
              child: Text(L10n.instance.t('common_manage')),
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
    final saved = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
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
                      Text(L10n.instance.t('customers_page_manage_tags'),
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Spacer(),
                      Text(L10n.instance.t('i18n_288', args: {'v0':'${sel.length}'}),
                          style: TextStyle(color: AppTheme.textSub)),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(L10n.instance.t('i18n_613', args: {'v0': widget.customer.name}),
                      style: TextStyle(
                          color: AppTheme.textSub, fontSize: 12)),
                  SizedBox(height: 8),
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
                          AppButton(
                            label: L10n.instance.t('customers_new_tag'),
                            icon: Icons.add,
                            kind: AppButtonKind.secondary,
                            size: AppButtonSize.small,
                            expand: false,
                            onPressed: () async {
                              final t = await _createTagDialog();
                              if (t != null) {
                                // 新建标签先落库拿 id（v1.45.0 标签上云走同步通道），
                                // 再加入列表并选中；直接 t.id! 会因 id 为空崩溃。
                                final id =
                                    await AppDb.instance.insertTag(t.name, t.color);
                                setSheet(() {
                                  tags.add(t.copyWith(id: id));
                                  sel.add(id);
                                  commit();
                                });
                              }
                            },
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              final changed = await _openTagManagePage();
                              if (ctx.mounted && changed == true) {
                                Navigator.pop(ctx, true);
                              }
                            },
                            icon: Icon(Icons.tune, size: 16),
                            label: Text(L10n.instance.t('customers_tag_pool_manage')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: Icon(Icons.check, size: 18),
                      label: Text(L10n.instance.t('common_done')),
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
        title: Text(edit == null ? L10n.instance.t('customers_new_tag') : L10n.instance.t('customers_edit_tag')),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                maxLength: 8,
                decoration: InputDecoration(
                    labelText: L10n.instance.t('customers_tag_label'), hintText: L10n.instance.t('customers_tag_example')),
              ),
              SizedBox(height: 4),
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
              child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
            onPressed: () => nameCtrl.text.trim().isEmpty
                ? null
                : Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_save')),
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
      MaterialPageRoute(builder: (_) => _TagManagePage()),
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
                  style: TextStyle(color: AppTheme.textSub))),
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
            SizedBox(height: 8),
            Text(title,
                style:
                    TextStyle(fontSize: 12, color: AppTheme.textSub)),
            SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          SizedBox(width: 4),
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
const   _TagManagePage();

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
        title: Text(edit == null ? L10n.instance.t('customers_new_tag') : L10n.instance.t('customers_edit_tag')),
        content: StatefulBuilder(
          builder: (ctx, setDlg) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                maxLength: 8,
                decoration: InputDecoration(
                    labelText: L10n.instance.t('customers_tag_label'), hintText: L10n.instance.t('customers_tag_example')),
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
              child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
            onPressed: () => nameCtrl.text.trim().isEmpty
                ? null
                : Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_save')),
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
        title: Text(L10n.instance.t('customers_delete_tag')),
        content: Text(L10n.instance.t('i18n_503', args: {'v0': name})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('common_delete'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
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
      appBar: AppBar(title: Text(L10n.instance.t('customers_tag_pool'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        icon: Icon(Icons.add),
        label: Text(L10n.instance.t('customers_new_tag')),
      ),
      body: _loading
          ? AppLoading()
          : _summaries.isEmpty
              ? AppEmpty(
                  icon: Icons.sell_outlined,
                  title: L10n.instance.t('customers_no_tags'))
              : ListView(
                  padding: const EdgeInsets.only(bottom: 88),
                  children: [
                    Container(
                      color: AppTheme.primary.withValues(alpha: 0.06),
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: AppTheme.primary),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              L10n.instance.t('i18n_465') +
                              L10n.instance.t('i18n_100'),
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
                            L10n.instance.t('customers_count_suffix', args: {'v0':'${s['customer_count'] ?? 0}'}) +
                            L10n.instance.t('customers_total_received', args: {'v0': _fmt.format(((s['paid_total'] as num?)?.toInt() ?? 0) / 100)}),
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
