import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../theme.dart';
import '../models.dart';
import '../database.dart';

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
  int _simpleTargetMode = 0; // 0=客户名称手动输入, 1=关联项目
  final _simpleNameCtrl = TextEditingController(); // 客户名称
  int? _simpleProjectId; // 关联项目
  int? _simpleCustomerId; // 关联客户档案（v1.10.0，可选）
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

  /// 简单报价对象名：客户名称 / 关联项目标题 二选一
  String get _simpleObjectName {
    if (_simpleTargetMode == 1 && _simpleProjectId != null) {
      for (final pr in _projects) {
        if (pr.id == _simpleProjectId) return pr.title;
      }
      return '';
    }
    return _simpleNameCtrl.text.trim();
  }

  /// 简单报价选中关联项目时，回填该项目所属客户名
  String get _simpleLinkedCustomerName {
    if (_simpleProjectId == null) return '';
    for (final pr in _projects) {
      if (pr.id == _simpleProjectId) {
        for (final c in _customers) {
          if (c.id == pr.customerId) return c.name;
        }
        return '';
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
      projectId: _simpleTargetMode == 1 ? _simpleProjectId : null,
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
                  return ListTile(
                    onTap: () {
                      if (q.isSimple) {
                        _loadSimpleQuote(q);
                      } else {
                        _loadQuote(q);
                      }
                      Navigator.pop(ctx);
                    },
                    leading: Icon(
                      q.isSimple ? Icons.bolt_outlined : Icons.description_outlined,
                      color: AppTheme.primary,
                    ),
                    title: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (q.isSimple ? AppTheme.primary : AppTheme.accent)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            q.isSimple ? '简单报价' : '详细报价',
                            style: TextStyle(
                              fontSize: 11,
                              color: q.isSimple ? AppTheme.primary : AppTheme.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(q.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                    subtitle: Text(
                        '¥${_fmt.format(q.total)} · ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(q.createdAt))}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert,
                              size: 20, color: AppTheme.textSub),
                          tooltip: '更多操作',
                          onSelected: (v) async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            if (v == 'to_pending') {
                              await _quoteToPendingCollection(q);
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                const SnackBar(content: Text('已转为待收款，可在看板查看待收尾款')),
                              );
                            } else if (v == 'to_project') {
                              final projectId =
                                  await _quoteToProject(q);
                              if (projectId == null || !ctx.mounted) return;
                              Navigator.pop(ctx);
                              messenger.showSnackBar(
                                const SnackBar(content: Text('已确认成交并创建正式项目')),
                              );
                            }
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem<String>(
                              value: 'to_pending',
                              child: Text('转为待收款'),
                            ),
                            const PopupMenuItem<String>(
                              value: 'to_project',
                              child: Text('确认成交转正式项目'),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_copy,
                              size: 20, color: AppTheme.textSub),
                          tooltip: '复制文本',
                          onPressed: () async {
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
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined,
                              size: 20, color: AppTheme.primary),
                          tooltip: '重新打开编辑',
                          onPressed: () {
                            if (q.isSimple) {
                              _loadSimpleQuote(q);
                            } else {
                              _loadQuote(q);
                            }
                            Navigator.pop(ctx);
                          },
                        ),
                        if (q.isSimple)
                          IconButton(
                            icon: const Icon(Icons.unfold_more,
                                size: 20, color: AppTheme.primary),
                            tooltip: '转为详细报价',
                            onPressed: () {
                              _convertToFull(q);
                              Navigator.pop(ctx);
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 20, color: AppTheme.danger),
                          tooltip: '删除',
                          onPressed: () async {
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
                        ),
                      ],
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
      b.writeln('报价金额：¥${_fmt.format(q.total)}');
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
  /// 载入简单报价历史到简单 Tab 编辑态
  void _loadSimpleQuote(Quote q) {
    setState(() {
      _tabController.index = 0; // 跳转简单 Tab
      _simpleQuoteId = q.id;
      _simpleCreatedAt = q.createdAt;
      _simpleCustomerId = q.customerId;
      _simpleAmountCtrl.text = _numText(q.total / 100);
      _simpleNoteCtrl.text = q.note;
      if (q.projectId != null) {
        _simpleTargetMode = 1;
        _simpleProjectId = q.projectId;
        _simpleNameCtrl.clear();
      } else {
        _simpleTargetMode = 0;
        _simpleProjectId = null;
        _simpleNameCtrl.text = q.title;
      }
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
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                  value: 0,
                  label: Text('客户名称'),
                  icon: Icon(Icons.person_outline, size: 18)),
              ButtonSegment(
                  value: 1,
                  label: Text('关联项目'),
                  icon: Icon(Icons.folder_outlined, size: 18)),
            ],
            selected: {_simpleTargetMode},
            onSelectionChanged: (s) {
              setState(() {
                _simpleTargetMode = s.first;
                // 互斥：切换时清空另一侧输入，保证"客户名称/关联项目"二选一
                if (s.first == 0) {
                  _simpleProjectId = null;
                } else {
                  _simpleNameCtrl.clear();
                }
              });
            },
          ),
          const SizedBox(height: 12),
          if (_simpleTargetMode == 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _simpleNameCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '输入客户名称',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: _simpleCustomerId,
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
                    _simpleCustomerId = v;
                    // 选中客户档案时自动回填客户名称
                    if (v != null) {
                      final c = _customers.firstWhere((x) => x.id == v);
                      _simpleNameCtrl.text = c.name;
                    }
                  }),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<int?>(
                  initialValue: _simpleProjectId,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('请选择关联项目')),
                    ..._projects.map((pr) => DropdownMenuItem<int?>(
                        value: pr.id, child: Text(pr.title))),
                  ],
                  onChanged: (v) => setState(() => _simpleProjectId = v),
                ),
                if (_simpleProjectId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '客户：$_simpleLinkedCustomerName',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSub),
                    ),
                  ),
              ],
            ),
          const Spacer(),
          // 大号报价总额输入框（C 位）
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
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
