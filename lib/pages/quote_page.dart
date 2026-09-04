import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../constants.dart';
import '../theme.dart';
import '../widgets/slidable_action.dart';
import '../models.dart';
import '../database.dart';
import '../services/quote_pdf_service.dart';

/// 报价单双 Tab 管理（v8 起支持 简单报价 / 详细报价）：
/// - 简单报价 Tab：一口价快速报价（客户/项目二选一 + 大号金额 + 备注），一屏内完成；
/// - 详细报价 Tab：保留原明细计税能力（工时/单价/物料费/税率/合计）；
/// - 两 Tab 表单数据完全隔离，切换不互相覆盖；
/// - 历史记录按类型标记，简单报价可一键转为详细报价。
class QuotePage extends StatefulWidget {
  /// 从项目详情进入时预选关联项目
  final int? initialProjectId;
  final String? initialTitle;

  const QuotePage({super.key, this.initialProjectId, this.initialTitle});

  @override
  State<QuotePage> createState() => _QuotePageState();
}

class _QuotePageState extends State<QuotePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // ================= 简单报价状态（与详细报价完全隔离） =================
  final _simpleNameCtrl = TextEditingController(); // 客户名称（也可由关联项目/档案回填）
  int? _simpleProjectId; // 关联项目（可选，v1.12.0 起与客户名称同屏展示）
  int? _simpleCustomerId; // 关联客户档案（可选）
  final _simpleAmountCtrl = TextEditingController(); // 报价总额
  final _simpleNoteCtrl = TextEditingController(); // 备注（可选）
  int? _simpleQuoteId; // 正在编辑的简单报价历史 id（null=新建）
  int? _simpleCreatedAt; // 编辑历史时保留原时间戳

  // ================= 详细报价状态（保留原有能力） =================
  final _lines = <QuoteLine>[
    const QuoteLine(itemName: '设计服务', hours: 8, hourRate: AppConfig.defaultHourRate),
  ];
  double _taxRate = AppConfig.defaultTaxRate;
  final _fmt = NumberFormat('#,##0.00');
  final _clientCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _taxCtrl = TextEditingController(); // 税率输入框（留空 = 按 0 计税）
  final _detailNoteCtrl = TextEditingController(); // 详细报价备注（可选）
  int? _quoteId; // 当前编辑的历史报价单 id（null=新建）
  int? _quoteCreatedAt; // 编辑历史时保留原时间戳
  int? _projectId; // 关联项目
  int? _detailCustomerId; // 关联客户档案（v1.10.0，可选）
  List<Project> _projects = [];
  List<Customer> _customers = []; // 关联项目回填客户名

  int get _subtotal =>
      _lines.fold(0, (sum, l) => sum + l.laborCost + l.materialFee);
  double get _tax => _subtotal * _taxRate;
  double get _total => _subtotal + _tax;

  /// 简单报价对象名：优先客户名称；未填客户名时回退到关联项目标题
  String get _simpleObjectName {
    final name = _simpleNameCtrl.text.trim();
    if (name.isNotEmpty) return name;
    if (_simpleProjectId != null) {
      for (final pr in _projects) {
        if (pr.id == _simpleProjectId) return pr.title;
      }
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    // 默认打开简单报价 Tab；从项目详情进入时仍优先打开详细报价并预填项目
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialProjectId != null ? 1 : 0,
    );
    _titleCtrl.text = widget.initialTitle ?? '';
    _projectId = widget.initialProjectId;
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final list = await AppDb.instance.getProjects();
    final customers = await AppDb.instance.getCustomers();
    if (mounted) {
      setState(() {
        _projects = list;
        _customers = customers;
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _simpleNameCtrl.dispose();
    _simpleAmountCtrl.dispose();
    _simpleNoteCtrl.dispose();
    _clientCtrl.dispose();
    _titleCtrl.dispose();
    _taxCtrl.dispose();
    _detailNoteCtrl.dispose();
    super.dispose();
  }

  // ================= 简单报价：文本生成 / 复制 =================
  String buildSimpleQuoteText() {
    final objectName = _simpleObjectName;
    final amount = double.tryParse(_simpleAmountCtrl.text.trim()) ?? 0;
    final note = _simpleNoteCtrl.text.trim();
    final b = StringBuffer()
      ..writeln('【报价】')
      ..writeln('客户：$objectName')
      ..writeln('报价金额：¥${_fmt.format(amount)}');
    if (note.isNotEmpty) {
      b.writeln('备注：$note');
    }
    return b.toString();
  }

  Future<void> _copySimpleToClipboard() async {
    await Clipboard.setData(ClipboardData(text: buildSimpleQuoteText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('报价单已复制，去微信/邮件里粘贴给客户吧')),
    );
  }

  // ================= 简单报价：保存 =================
  Future<void> _saveSimpleQuote() async {
    final objectName = _simpleObjectName;
    if (objectName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写报价对象（客户名称或选择关联项目）')),
      );
      return;
    }
    final amount = double.tryParse(_simpleAmountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写报价金额')),
      );
      return;
    }
    final note = _simpleNoteCtrl.text.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    final q = Quote(
      id: _simpleQuoteId,
      projectId: _simpleProjectId,
      customerId: _simpleCustomerId,
      title: objectName,
      taxRate: 0,
      lines: const [],
      total: Money.parseYuanToFen(amount.toStringAsFixed(2)),
      createdAt: _simpleCreatedAt ?? now,
      type: 'simple',
      note: note,
      taxInclude: true,
    );
    if (_simpleQuoteId == null) {
      await AppDb.instance.insertQuote(q);
    } else {
      await AppDb.instance.updateQuote(q);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_simpleQuoteId == null ? '报价单已保存到历史' : '报价单已更新')),
    );
    // 保存成功后重置为初始新建状态
    setState(() {
      _simpleQuoteId = null;
      _simpleCreatedAt = null;
      _simpleProjectId = null;
      _simpleCustomerId = null;
      _simpleNameCtrl.clear();
      _simpleAmountCtrl.clear();
      _simpleNoteCtrl.clear();
    });
  }

  // ================= 详细报价：文本生成 / 复制（保留原逻辑） =================
  String buildQuoteText() {
    final b = StringBuffer()
      ..writeln('【报价单】')
      ..writeln('客户：${_clientCtrl.text.trim().isEmpty ? '________' : _clientCtrl.text.trim()}');
    b.writeln('------------------');
    for (int i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      b.writeln('${i + 1}. ${l.itemName}');
      if (l.hours > 0) {
        b.writeln('   工时 ${l.hours}h × ${_fmt.format(l.hourRate / 100)}元/h = ${_fmt.format(l.laborCost / 100)}元');
      }
      if (l.materialFee > 0) {
        b.writeln('   物料 ${_fmt.format(l.materialFee / 100)}元');
      }
    }
    b.writeln('------------------');
    b.writeln('小计：${_fmt.format(_subtotal / 100)} 元');
    b.writeln('税费（${(_taxRate * 100).toStringAsFixed(0)}%）：${_fmt.format(_tax / 100)} 元');
    b.writeln('合计：${_fmt.format(_total / 100)} 元');
    b.writeln('请确认无误后回复，感谢合作！');
    return b.toString();
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: buildQuoteText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('报价单已复制，去微信/邮件里粘贴给客户吧')),
    );
  }

  // ================= 详细报价：保存（保留原逻辑 + 备注/类型） =================
  Future<void> _saveQuote() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写报价单标题（如客户 / 项目名）')),
      );
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final q = Quote(
      id: _quoteId,
      projectId: _projectId,
      customerId: _detailCustomerId,
      title: title,
      taxRate: _taxRate * 100, // 模型存百分比
      lines: List.of(_lines),
      total: _total.round(),
      createdAt: _quoteCreatedAt ?? now,
      type: 'full',
      note: _detailNoteCtrl.text.trim(),
      taxInclude: true,
    );
    if (_quoteId == null) {
      await AppDb.instance.insertQuote(q);
    } else {
      await AppDb.instance.updateQuote(q);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_quoteId == null ? '报价单已保存到历史' : '报价单已更新')),
    );
    // 保存成功后重置为初始新建状态，方便直接开始填下一份报价
    setState(() {
      _quoteId = null;
      _quoteCreatedAt = null;
      _projectId = null;
      _detailCustomerId = null;
      _titleCtrl.clear();
      _clientCtrl.clear();
      _taxCtrl.clear();
      _detailNoteCtrl.clear();
      _taxRate = AppConfig.defaultTaxRate;
      _lines
        ..clear()
        ..add(const QuoteLine(
            itemName: '设计服务', hours: 8, hourRate: AppConfig.defaultHourRate));
    });
  }

  // ================= 简单报价 → 详细报价 =================
  void _convertToFull(Quote q) {
    setState(() {
      _tabController.index = 1; // 切到详细 Tab
      _quoteId = null; // 作为新报价重新出单
      _quoteCreatedAt = null;
      _titleCtrl.text = q.title;
      _projectId = q.projectId;
      _clientCtrl.text = q.title; // 客户名称沿用报价对象名
      _taxRate = AppConfig.defaultTaxRate;
      _taxCtrl.clear();
      _detailNoteCtrl.text = q.note;
      // 金额自动生成一行明细：项目名=报价对象名、工时=1、单价=报价金额
      _lines
        ..clear()
        ..add(QuoteLine(itemName: q.title, hours: 1, hourRate: q.total));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已转为详细报价，可继续调整明细')),
    );
  }

  // ================= 报价 → 待收款 / 正式项目（v1.10.0） =================
  /// 报价转为待收款：调用已有 pending_collections 插入逻辑
  Future<void> _quoteToPendingCollection(Quote q) async {
    await AppDb.instance.insertPendingCollection(PendingCollection(
      quoteId: q.id,
      projectId: q.projectId,
      customerId: q.customerId,
      title: q.title,
      amount: q.total,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 报价确认成交转正式项目：需关联客户（无则弹窗选/建客户），
  /// 创建项目后回写报价的 projectId 关联
  Future<int?> _quoteToProject(Quote q) async {
    int? customerId = q.customerId;
    if (customerId == null) {
      customerId = await _pickCustomerForProject(q.title);
      if (customerId == null) return null; // 用户取消
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final projectId = await AppDb.instance.insertProject(Project(
      customerId: customerId,
      title: q.title,
      status: ProjectStatus.accepted,
      amountTotal: q.total,
      createdAt: now,
      updatedAt: now,
    ));
    // 回写报价的 projectId 关联
    final updated = Quote(
      id: q.id,
      projectId: projectId,
      customerId: q.customerId ?? customerId,
      title: q.title,
      taxRate: q.taxRate,
      lines: q.lines,
      total: q.total,
      createdAt: q.createdAt,
      type: q.type,
      note: q.note,
      taxInclude: q.taxInclude,
    );
    if (q.id != null) {
      await AppDb.instance.updateQuote(updated);
    }
    return projectId;
  }

  /// 报价无关联客户时弹窗选择已有客户或新建客户（返回 null 表示取消）
  Future<int?> _pickCustomerForProject(String quoteTitle) async {
    final customers = await AppDb.instance.getCustomers();
    if (!mounted) return null;
    final nameCtrl = TextEditingController();
    int? selected = customers.length == 1 ? customers.first.id : null;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('确认成交 · 选择客户'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将「$quoteTitle」转为正式项目，需指定所属客户：',
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSub)),
              const SizedBox(height: 12),
              if (customers.isNotEmpty) ...[
                DropdownButtonFormField<int>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      isDense: true, labelText: '已有客户'),
                  items: customers
                      .map((c) => DropdownMenuItem<int>(
                          value: c.id!, child: Text(c.name)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    selected = v;
                    nameCtrl.clear();
                  }),
                ),
                const SizedBox(height: 12),
                const Divider(),
                const Text('或新建客户：',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
                const SizedBox(height: 6),
              ],
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: '新客户名称',
                ),
                onChanged: (v) => setState(() {
                  if (v.trim().isNotEmpty) selected = null;
                }),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final newName = nameCtrl.text.trim();
                if (newName.isNotEmpty) {
                  // 新建客户并返回其 id
                  AppDb.instance
                      .insertCustomer(Customer(
                        name: newName,
                        createdAt: DateTime.now().millisecondsSinceEpoch,
                      ))
                      .then((id) {
                        if (ctx.mounted) Navigator.pop(ctx, id);
                      });
                } else if (selected != null) {
                  Navigator.pop(ctx, selected);
                }
              },
              child: const Text('确认成交'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    return result;
  }

  // ================= 历史弹层 =================
  Future<void> _openHistory() async {
    final quotes = await AppDb.instance.getQuotes();
    if (!mounted) return;
    if (quotes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有保存过报价单')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('报价历史',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: quotes.length,
                itemBuilder: (ctx, i) {
                  final q = quotes[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    child: Slidable(
                      key: ValueKey('quote_${q.id}'),
                    endActionPane: ActionPane(
                      motion: const ScrollMotion(),
                      extentRatio: 0.72,
                      children: [
                        CustomSlidableAction(
                          onPressed: (_) async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            await Clipboard.setData(ClipboardData(
                                text: _quoteTextFor(q)));
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            messenger.showSnackBar(
                              const SnackBar(content: Text('报价单文本已复制')),
                            );
                          },
                          backgroundColor: AppTheme.accent,
                          foregroundColor: Colors.white,
                          borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(12)),
                          child: const SlidableActionContent(
                              icon: Icons.content_copy, label: '复制'),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) {
                            _openQuoteForEdit(q);
                            Navigator.pop(ctx);
                          },
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          child: const SlidableActionContent(
                              icon: Icons.edit_outlined, label: '编辑'),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            final action = await showModalBottomSheet<String>(
                              context: ctx,
                              builder: (sctx) => SafeArea(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: const Icon(Icons.trending_up,
                                          color: AppTheme.accent),
                                      title: const Text('转为待收款'),
                                      onTap: () =>
                                          Navigator.pop(sctx, 'to_pending'),
                                    ),
                                    ListTile(
                                      leading: const Icon(Icons.assignment_outlined,
                                          color: AppTheme.primary),
                                      title: const Text('确认成交转正式项目'),
                                      onTap: () =>
                                          Navigator.pop(sctx, 'to_project'),
                                    ),
                                    if (q.isSimple)
                                      ListTile(
                                        leading: const Icon(Icons.unfold_more,
                                            color: AppTheme.accent),
                                        title: const Text('转为详细报价'),
                                        onTap: () =>
                                            Navigator.pop(sctx, 'to_full'),
                                      ),
                                  ],
                                ),
                              ),
                            );
                            if (action == null || !ctx.mounted) return;
                            if (action == 'to_pending') {
                              await _quoteToPendingCollection(q);
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              messenger.showSnackBar(const SnackBar(
                                  content: Text('已转为待收款，可在看板查看待收尾款')));
                            } else if (action == 'to_project') {
                              final projectId = await _quoteToProject(q);
                              if (projectId == null || !ctx.mounted) return;
                              Navigator.pop(ctx);
                              messenger.showSnackBar(const SnackBar(
                                  content: Text('已确认成交并创建正式项目')));
                            } else if (action == 'to_full') {
                              _convertToFull(q);
                              Navigator.pop(ctx);
                            }
                          },
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          child: const SlidableActionContent(
                              icon: Icons.swap_horiz, label: '流转'),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: const Text('删除报价单'),
                                content: Text('确定删除「${q.title}」吗？'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dctx, false),
                                      child: const Text('取消')),
                                  FilledButton(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: AppTheme.danger),
                                    onPressed: () =>
                                        Navigator.pop(dctx, true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            await AppDb.instance.deleteQuote(q.id!);
                            if (!mounted) return;
                            messenger.showSnackBar(
                              const SnackBar(content: Text('已删除报价单')),
                            );
                            _openHistory();
                          },
                          backgroundColor: AppTheme.danger,
                          foregroundColor: Colors.white,
                          borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(12)),
                          child: const SlidableActionContent(
                              icon: Icons.delete_outline, label: '删除'),
                        ),
                      ],
                    ),
                      child: Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          _openQuoteForEdit(q);
                          Navigator.pop(ctx);
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: (q.isSimple
                                              ? AppTheme.primary
                                              : AppTheme.accent)
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      q.isSimple ? '简单报价' : '详细报价',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: q.isSimple
                                            ? AppTheme.primary
                                            : AppTheme.accent,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(q.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '¥${_fmt.format(q.total / 100)}',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                DateFormat('yyyy-MM-dd HH:mm').format(
                                    DateTime.fromMillisecondsSinceEpoch(
                                        q.createdAt)),
                                style: const TextStyle(
                                    fontSize: 12, color: AppTheme.textSub),
                              ),
                            ],
                          ),
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
      ),
    );
  }

  /// 按历史报价单生成文本（不依赖当前编辑态），简单/详细分别处理
  String _quoteTextFor(Quote q) {
    if (q.isSimple) {
      final b = StringBuffer()
        ..writeln('【报价】')
        ..writeln('客户：${q.title}');
      b.writeln('报价金额：¥${_fmt.format(q.total / 100)}');
      if (q.note.trim().isNotEmpty) {
        b.writeln('备注：${q.note.trim()}');
      }
      return b.toString();
    }
    final sub = q.lines.fold<double>(
        0, (s, l) => s + l.laborCost + l.materialFee);
    final tax = sub * (q.taxRate / 100);
    final b = StringBuffer()
      ..writeln('【报价单】')
      ..writeln('客户：${q.title}');
    b.writeln('------------------');
    for (int i = 0; i < q.lines.length; i++) {
      final l = q.lines[i];
      b.writeln('${i + 1}. ${l.itemName}');
      if (l.hours > 0) {
        b.writeln('   工时 ${l.hours}h × ${_fmt.format(l.hourRate / 100)}元/h = ${_fmt.format(l.laborCost / 100)}元');
      }
      if (l.materialFee > 0) {
        b.writeln('   物料 ${_fmt.format(l.materialFee / 100)}元');
      }
    }
    b.writeln('------------------');
    b.writeln('小计：${_fmt.format(sub / 100)} 元');
    b.writeln('税费（${q.taxRate.toStringAsFixed(0)}%）：${_fmt.format(tax / 100)} 元');
    b.writeln('合计：${_fmt.format(q.total / 100)} 元');
    b.writeln('请确认无误后回复，感谢合作！');
    return b.toString();
  }

  // ================= 历史载入 =================
  /// 统一编辑入口：按报价类型打开对应 Tab（简单→简单 Tab，详细→详细 Tab），
  /// 并在下一帧兜底锁定 Tab 索引。用于消除历史弹层关闭与 TabBarView 动画
  /// 并发时，TabController 索引短暂漂移导致简单报价被切到详细 Tab 的竞态。
  void _openQuoteForEdit(Quote q) {
    if (q.isSimple) {
      _loadSimpleQuote(q);
    } else {
      _loadQuote(q);
    }
    _lockTabTo(q.isSimple ? 0 : 1);
  }

  /// 兜底：等当前帧（含弹层关闭/切页动画）结束后，再次核对并强制收敛
  /// 到目标 Tab 索引，保证简单/详细模式与所编辑报价类型严格一致。
  void _lockTabTo(int target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabController.index == target) return;
      _tabController.index = target;
    });
  }

  /// 载入简单报价历史到简单 Tab 编辑态
  void _loadSimpleQuote(Quote q) {
    setState(() {
      _tabController.index = 0; // 跳转简单 Tab
      _simpleQuoteId = q.id;
      _simpleCreatedAt = q.createdAt;
      _simpleCustomerId = q.customerId;
      _simpleAmountCtrl.text = _numText(q.total / 100);
      _simpleNoteCtrl.text = q.note;
      _simpleProjectId = q.projectId;
      _simpleNameCtrl.text = q.title;
    });
  }

  /// 把详细报价历史载入编辑态（保留原逻辑 + 备注）
  void _loadQuote(Quote q) {
    setState(() {
      _tabController.index = 1; // 跳转详细 Tab
      _quoteId = q.id;
      _quoteCreatedAt = q.createdAt;
      _detailCustomerId = q.customerId;
      _titleCtrl.text = q.title;
      _projectId = q.projectId;
      _clientCtrl.text = q.title;
      _taxRate = q.taxRate / 100;
      _taxCtrl.text = q.taxRate.toStringAsFixed(0); // 同步税率输入框（历史存百分比）
      _detailNoteCtrl.text = q.note;
      _lines
        ..clear()
        ..addAll(q.lines.isEmpty
            ? [const QuoteLine(itemName: '设计服务', hours: 8, hourRate: AppConfig.defaultHourRate)]
            : q.lines);
    });
  }

  String _numText(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  // ================= 简单报价 Tab（一屏内不滚动） =================

  /// 关联客户档案：底部弹层选择器（替代原 Dropdown，v1.11.0 改）
  Future<void> _pickSimpleCustomer() async {
    final selected = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CustomerPickerSheet(
        customers: _customers,
        selectedId: _simpleCustomerId,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _simpleCustomerId = selected == -1 ? null : selected;
      // 选中客户档案时自动回填客户名称
      if (_simpleCustomerId != null) {
        final c = _customers.firstWhere((x) => x.id == _simpleCustomerId);
        _simpleNameCtrl.text = c.name;
      }
    });
  }

  /// 关联项目：底部弹层选择器（v1.12.0 改，替代原丑下拉）
  Future<void> _pickSimpleProject() async {
    final selected = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ProjectPickerSheet(
        projects: _projects,
        customers: _customers,
        selectedId: _simpleProjectId,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _simpleProjectId = selected == -1 ? null : selected;
      // 选中关联项目且客户名未填时，自动回填该项目所属客户名
      if (_simpleProjectId != null && _simpleNameCtrl.text.trim().isEmpty) {
        for (final pr in _projects) {
          if (pr.id == _simpleProjectId) {
            for (final c in _customers) {
              if (c.id == pr.customerId && c.name.isNotEmpty) {
                _simpleNameCtrl.text = c.name;
              }
            }
            break;
          }
        }
      }
    });
  }

  Widget _buildSimpleTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('报价对象',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _simpleNameCtrl,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: '输入客户名称',
            ),
          ),
          const SizedBox(height: 8),
          // 关联项目：轻量入口 + 底部弹层选择（v1.12.0 改，替代原丑下拉）
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _pickSimpleProject,
            child: InputDecorator(
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined,
                      size: 18,
                      color: _simpleProjectId == null
                          ? AppTheme.textSub
                          : AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _simpleProjectId == null
                          ? '关联项目（可选）'
                          : _projects
                                  .firstWhere((p) => p.id == _simpleProjectId)
                                  .title,
                      style: TextStyle(
                        fontSize: 14,
                        color: _simpleProjectId == null
                            ? AppTheme.textSub
                            : AppTheme.textMain,
                      ),
                    ),
                  ),
                  if (_simpleProjectId != null)
                    GestureDetector(
                      onTap: () => setState(() => _simpleProjectId = null),
                      child: const Icon(Icons.close,
                          size: 16, color: AppTheme.textSub),
                    )
                  else
                    const Icon(Icons.chevron_right,
                        size: 18, color: AppTheme.textSub),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 关联客户档案：轻量入口 + 底部弹层选择
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _pickSimpleCustomer,
            child: InputDecorator(
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              child: Row(
                children: [
                  Icon(Icons.badge_outlined,
                      size: 18,
                      color: _simpleCustomerId == null
                          ? AppTheme.textSub
                          : AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _simpleCustomerId == null
                          ? '关联客户档案（可选）'
                          : _customers
                                  .firstWhere((c) => c.id == _simpleCustomerId)
                                  .name,
                      style: TextStyle(
                        fontSize: 14,
                        color: _simpleCustomerId == null
                            ? AppTheme.textSub
                            : AppTheme.textMain,
                      ),
                    ),
                  ),
                  if (_simpleCustomerId != null)
                    GestureDetector(
                      onTap: () => setState(() => _simpleCustomerId = null),
                      child: const Icon(Icons.close,
                          size: 16, color: AppTheme.textSub),
                    )
                  else
                    const Icon(Icons.chevron_right,
                        size: 18, color: AppTheme.textSub),
                ],
              ),
            ),
          ),
          const Spacer(),
          // 大号报价总额输入框（C 位）
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (MediaQuery.sizeOf(context).width * 0.66)
                    .clamp(280.0, 480.0),
              ),
              child: TextField(
                controller: _simpleAmountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary),
                decoration: const InputDecoration(
                  hintText: '0.00',
                  prefixText: '¥ ',
                  prefixStyle: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primary),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('报价总额（一口价含税）',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textSub)),
          ),
          const Spacer(),
          // 备注：固定小高度，超出内部滚动
          const Text('备注（可选）',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          SizedBox(
            height: 72,
            child: TextField(
              controller: _simpleNoteCtrl,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                hintText: '补充说明，如交付时间、付款方式等',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ================= 详细报价 Tab（保留原有逻辑） =================
  Widget _buildDetailTab() {
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('报价单标题',
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                TextField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '如：品牌官网改版报价',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('客户名称',
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                TextField(
                  controller: _clientCtrl,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: _detailCustomerId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '关联客户档案（可选）',
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('不关联')),
                    ..._customers.map((c) => DropdownMenuItem<int?>(
                        value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (v) => setState(() {
                    _detailCustomerId = v;
                    if (v != null) {
                      final c = _customers.firstWhere((x) => x.id == v);
                      _clientCtrl.text = c.name;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                const Text('关联项目（可选）',
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                DropdownButtonFormField<int?>(
                  initialValue: _projectId,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('不关联项目')),
                    ..._projects.map((pr) => DropdownMenuItem<int?>(
                        value: pr.id, child: Text(pr.title))),
                  ],
                  onChanged: (v) => setState(() => _projectId = v),
                ),
                const SizedBox(height: 12),
                const Text('备注（可选）',
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                TextField(
                  controller: _detailNoteCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '补充说明（随报价单保存到历史）',
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          child: Row(
            children: [
              const Expanded(child: Text('费用项目', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              TextButton.icon(
                onPressed: () => setState(() => _lines.add(const QuoteLine(itemName: ''))),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('加一行'),
              ),
            ],
          ),
        ),
        ..._lines.asMap().entries.map((entry) => _LineCard(
              index: entry.key,
              line: entry.value,
              onChanged: (l) => setState(() => _lines[entry.key] = l),
              onRemove: _lines.length > 1
                  ? () => setState(() => _lines.removeAt(entry.key))
                  : null,
            )),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Text('税率'),
                const Spacer(),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _taxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(
                      suffixText: '%',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    onChanged: (v) {
                      final n = double.tryParse(v);
                      setState(() => _taxRate = (n ?? 0) / 100);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          color: AppTheme.primary,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('费用小计', '¥${_fmt.format(_subtotal / 100)}', Colors.white70),
                _row('税费', '¥${_fmt.format(_tax / 100)}', Colors.white70),
                const Divider(color: Colors.white24),
                _row('本次报价合计', '¥${_fmt.format(_total / 100)}', Colors.white, bold: true, big: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ================= 报价单 PDF 导出（简单 / 详细统一） =================
  String _projectTitle(int? id) {
    if (id == null) return '';
    for (final pr in _projects) {
      if (pr.id == id) return pr.title;
    }
    return '';
  }

  /// 自定义落款：个人 / 工作室名称 + 联系方式（本地持久化，导出时自动带上）。
  Future<void> _editSignature() async {
    final sig = await QuotePdfService.readSignature();
    if (!mounted) return;
    final nameCtrl = TextEditingController(text: sig.name);
    final contactCtrl = TextEditingController(text: sig.contact);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('报价单落款'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '显示在报价单底部，PDF 导出时自动带上。',
                style: TextStyle(color: AppTheme.textSub, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: '落款名称',
                  hintText: '如：李工 / 某某工作室',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contactCtrl,
                decoration: const InputDecoration(
                  labelText: '联系方式',
                  hintText: '电话 / 微信 / 邮箱',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await QuotePdfService.saveSignature(
        name: nameCtrl.text,
        contact: contactCtrl.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('落款已保存')),
      );
    }
  }

  Future<void> _exportSimplePdf() async {
    final objectName = _simpleObjectName;
    if (objectName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写报价对象（客户名称或选择关联项目）')),
      );
      return;
    }
    final amount = double.tryParse(_simpleAmountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写报价金额')),
      );
      return;
    }
    final sig = await QuotePdfService.readSignature();
    final name = _simpleNameCtrl.text.trim();
    final projTitle = _projectTitle(_simpleProjectId);
    await _sharePdf(QuotePdfData(
      title: name.isNotEmpty ? name : projTitle,
      type: 'simple',
      total: Money.parseYuanToFen(amount.toStringAsFixed(2)),
      note: _simpleNoteCtrl.text.trim(),
      customerName: name.isNotEmpty ? name : projTitle,
      projectName: name.isNotEmpty ? projTitle : '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      signName: sig.name,
      signContact: sig.contact,
    ));
  }

  Future<void> _exportFullPdf() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写客户 / 项目名称')),
      );
      return;
    }
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少添加一项报价明细')),
      );
      return;
    }
    final sig = await QuotePdfService.readSignature();
    String customerName = '';
    if (_detailCustomerId != null) {
      for (final c in _customers) {
        if (c.id == _detailCustomerId) {
          customerName = c.name;
          break;
        }
      }
    }
    await _sharePdf(QuotePdfData(
      title: title,
      type: 'full',
      total: _total.round(),
      subtotal: _subtotal.toDouble(),
      tax: _tax,
      taxRate: _taxRate,
      lines: List.of(_lines),
      note: _detailNoteCtrl.text.trim(),
      customerName: customerName.isEmpty ? title : customerName,
      projectName: _projectTitle(_projectId),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      signName: sig.name,
      signContact: sig.contact,
    ));
  }

  /// 生成 PDF 并拉起系统分享（带轻量生成中提示）。
  Future<void> _sharePdf(QuotePdfData data) async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Dialog(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 16),
              Text('正在生成报价单 PDF…'),
            ],
          ),
        ),
      ),
    );
    try {
      await QuotePdfService.export(context, data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF 导出失败：$e')),
      );
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('报价单'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSub,
          indicatorColor: AppTheme.primary,
          tabs: const [
            Tab(text: '简单报价'),
            Tab(text: '详细报价'),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _editSignature,
            icon: const Icon(Icons.edit_note, size: 18),
            label: const Text('落款'),
          ),
          TextButton.icon(
            onPressed: _openHistory,
            icon: const Icon(Icons.history, size: 18),
            label: const Text('历史'),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSimpleTab(),
          _buildDetailTab(),
        ],
      ),
      // 底部常驻操作区：随当前 Tab 切换回调，不随内容滚走
      bottomNavigationBar: SafeArea(
        child: AnimatedBuilder(
          animation: _tabController,
          builder: (context, _) {
            final isSimple = _tabController.index == 0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: isSimple ? _copySimpleToClipboard : _copyToClipboard,
                      icon: const Icon(Icons.content_copy),
                      label: const Text('生成并复制'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: isSimple ? _saveSimpleQuote : _saveQuote,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        isSimple
                            ? (_simpleQuoteId == null ? '保存到历史' : '更新保存')
                            : (_quoteId == null ? '保存到历史' : '更新保存'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: isSimple ? _exportSimplePdf : _exportFullPdf,
                      icon: const Icon(Icons.picture_as_pdf),
                      label: Text(
                        isSimple ? '导出PDF' : '导出PDF',
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _row(String label, String value, Color color, {bool bold = false, bool big = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: color, fontSize: big ? 14 : 13)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: big ? 22 : 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
        ],
      ),
    );
  }
}

class _LineCard extends StatefulWidget {
  final int index;
  final QuoteLine line;
  final ValueChanged<QuoteLine> onChanged;
  final VoidCallback? onRemove;

  const _LineCard({required this.index, required this.line, required this.onChanged, this.onRemove});

  @override
  State<_LineCard> createState() => _LineCardState();
}

class _LineCardState extends State<_LineCard> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hoursCtrl;
  late final TextEditingController _rateCtrl;
  late final TextEditingController _matCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.line.itemName);
    _hoursCtrl = TextEditingController(text: widget.line.hours == 0 ? '' : widget.line.hours.toString());
    _rateCtrl = TextEditingController(text: widget.line.hourRate == 0 ? '' : Money.yuan(widget.line.hourRate));
    _matCtrl = TextEditingController(text: widget.line.materialFee == 0 ? '' : Money.yuan(widget.line.materialFee));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hoursCtrl.dispose();
    _rateCtrl.dispose();
    _matCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(QuoteLine(
        itemName: _nameCtrl.text.trim(),
        hours: double.tryParse(_hoursCtrl.text.trim()) ?? 0,
        hourRate: Money.parseYuanToFen(_rateCtrl.text.trim()),
        materialFee: Money.parseYuanToFen(_matCtrl.text.trim()),
      ));

  Widget _rowLabel(String text) => Text(
        text,
        style: const TextStyle(fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500),
      );

  InputDecoration _dec() => InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        border: const OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppTheme.textSub.withValues(alpha: 0.35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final nameCtrl = _nameCtrl;
    final hoursCtrl = _hoursCtrl;
    final rateCtrl = _rateCtrl;
    final matCtrl = _matCtrl;
    final onRemove = widget.onRemove;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
                  child: Text('${widget.index + 1}', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel('项目名称'),
                      const SizedBox(height: 6),
                      TextField(
                        controller: nameCtrl,
                        onChanged: (_) => _emit(),
                        decoration: _dec(),
                      ),
                    ],
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.close, size: 18, color: AppTheme.textSub),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel('工时(h)'),
                      const SizedBox(height: 6),
                      TextField(
                        controller: hoursCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => _emit(),
                        decoration: _dec(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel('单价(元/h)'),
                      const SizedBox(height: 6),
                      TextField(
                        controller: rateCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => _emit(),
                        decoration: _dec(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel('物料费(元)'),
                      const SizedBox(height: 6),
                      TextField(
                        controller: matCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => _emit(),
                        decoration: _dec(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 关联项目：底部弹层选择器（v1.12.0 改，替代原丑下拉）
class _ProjectPickerSheet extends StatelessWidget {
  final List<Project> projects;
  final List<Customer> customers;
  final int? selectedId;
  const _ProjectPickerSheet({
    required this.projects,
    required this.customers,
    required this.selectedId,
  });

  String _customerName(int customerId) {
    for (final c in customers) {
      if (c.id == customerId) return c.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final hasProjects = projects.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE4E7EF),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text('关联项目',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textMain)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Text('选中后若未填客户名会自动回填所属客户',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.block,
                      size: 20, color: AppTheme.textSub),
                  title: const Text('不关联',
                      style: TextStyle(color: AppTheme.textSub)),
                  trailing: selectedId == null
                      ? const Icon(Icons.check,
                          size: 18, color: AppTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, -1),
                ),
                if (!hasProjects)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('还没有项目，可在项目页先添加',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textSub)),
                  ),
                ...projects.map((pr) => ListTile(
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            AppTheme.primary.withValues(alpha: 0.1),
                        child: Text(
                          pr.title.characters.isEmpty
                              ? '?'
                              : pr.title.characters.first,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                      title: Text(pr.title,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: _customerName(pr.customerId).isNotEmpty
                          ? Text(_customerName(pr.customerId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12))
                          : null,
                      trailing: selectedId == pr.id
                          ? const Icon(Icons.check,
                              size: 18, color: AppTheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, pr.id),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 关联客户档案：底部弹层选择器（v1.11.0 改）
class _CustomerPickerSheet extends StatelessWidget {
  final List<Customer> customers;
  final int? selectedId;
  const _CustomerPickerSheet({required this.customers, required this.selectedId});

  @override
  Widget build(BuildContext context) {
    final hasCustomers = customers.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFE4E7EF),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text('关联客户档案',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textMain)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Text('选中后自动回填客户名称',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.block,
                      size: 20, color: AppTheme.textSub),
                  title: const Text('不关联',
                      style: TextStyle(color: AppTheme.textSub)),
                  trailing: selectedId == null
                      ? const Icon(Icons.check,
                          size: 18, color: AppTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, -1),
                ),
                if (!hasCustomers)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('还没有客户档案，可在客户页先添加',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textSub)),
                  ),
                ...customers.map((c) => ListTile(
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            AppTheme.primary.withValues(alpha: 0.1),
                        child: Text(
                          c.name.characters.first,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                      title: Text(c.name,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: c.contact.isNotEmpty
                          ? Text(c.contact,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12))
                          : null,
                      trailing: selectedId == c.id
                          ? const Icon(Icons.check,
                              size: 18, color: AppTheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, c.id),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
