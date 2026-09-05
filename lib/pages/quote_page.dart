import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../theme.dart';
import '../widgets/slidable_action.dart';
import '../models.dart';
import '../database.dart';
import '../services/quote_pdf_service.dart';
import '../services/quote_web_service.dart';
import '../utils/money_input.dart';

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
  final _simpleTaxCtrl = TextEditingController(); // 适用税率(%)
  double _simpleTaxRate = 0; // 简单报价税率（0-1），v1.24.0 起可按单设置
  int? _simpleQuoteId; // 正在编辑的简单报价历史 id（null=新建）
  int? _simpleCreatedAt; // 编辑历史时保留原时间戳

  // ================= 报价参考图（v1.24.0，两 Tab 共享） =================
  // 图片复制到应用文档目录 quote_images/ 下，仅存本地不上传；路径写入 quotes.image_path。
  String _imagePath = '';

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

  // ================= 报价参考图（v1.24.0） =================
  Future<void> _pickQuoteImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (picked == null || !mounted) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}quote_images');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = picked.path.split('.').last.toLowerCase();
      final safeExt =
          (ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'webp') ? ext : 'jpg';
      final dest = '${dir.path}${Platform.pathSeparator}'
          'quote_${DateTime.now().millisecondsSinceEpoch}.$safeExt';
      await File(picked.path).copy(dest);
      setState(() => _imagePath = dest);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('参考图已添加（仅保存在本机，不上传）')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片保存失败，请重试')),
      );
    }
  }

  void _removeQuoteImage() {
    setState(() => _imagePath = '');
  }

  void _viewQuoteImage() {
    if (_imagePath.isNotEmpty) _viewImagePath(_imagePath);
  }

  /// 查看某条报价参考图大图（历史详情 / 编辑预览共用，自动容错失效图片）。
  void _viewImagePath(String path) {
    if (path.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Padding(
              padding: EdgeInsets.all(32),
              child: Text('图片已失效，可重新选择',
                  style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }

  /// 参考图选择区（简单 / 详细 Tab 共用，附于报价表单，随报价保存到本地并展示）。
  Widget _buildQuoteImageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('参考图（可选）',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        const Text('插入本地参考图，仅保存在本机不上传，会随报价详情一起展示',
            style: TextStyle(fontSize: 11, color: AppTheme.textSub)),
        const SizedBox(height: 8),
        if (_imagePath.isNotEmpty)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: _viewQuoteImage,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_imagePath),
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 120,
                      height: 120,
                      color: AppTheme.bgCard,
                      alignment: Alignment.center,
                      child: const Icon(Icons.broken_image_outlined, color: AppTheme.textSub),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextButton.icon(
                    onPressed: _viewQuoteImage,
                    icon: const Icon(Icons.zoom_in, size: 18),
                    label: const Text('查看大图'),
                  ),
                  TextButton.icon(
                    onPressed: _removeQuoteImage,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('移除'),
                  ),
                ],
              ),
            ],
          )
        else
          OutlinedButton.icon(
            onPressed: _pickQuoteImage,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text('选择参考图'),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _simpleNameCtrl.dispose();
    _simpleAmountCtrl.dispose();
    _simpleNoteCtrl.dispose();
    _simpleTaxCtrl.dispose();
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
      taxRate: _simpleTaxRate * 100, // 存百分数，兼容历史简单报价默认 0
      lines: const [],
      total: Money.parseYuanToFen(amount.toStringAsFixed(2)),
      createdAt: _simpleCreatedAt ?? now,
      type: 'simple',
      note: note,
      taxInclude: true,
      imagePath: _imagePath,
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
      _simpleTaxCtrl.clear();
      _simpleTaxRate = 0;
      _imagePath = '';
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
      imagePath: _imagePath,
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
      _imagePath = '';
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

  // ================= v1.25.0 分享网页版报价单 =================
  /// 本地生成自包含 HTML 报价页（内联样式 / 手机浏览器自适应）并拉起系统分享
  /// 面板发送给客户（微信 / QQ / 邮件等）；业务数据仅存本地，不上传服务器。
  Future<void> _shareWeb(BuildContext ctx, Quote q) async {
    final messenger = ScaffoldMessenger.of(ctx);
    final sig = await QuotePdfService.readSignature();
    String customerName = q.title;
    if (q.customerId != null) {
      for (final c in _customers) {
        if (c.id == q.customerId) {
          customerName = c.name;
          break;
        }
      }
    }
    try {
      await QuoteWebService.share(QuoteWebData(
        quote: q,
        customerName: customerName,
        projectName: _projectTitle(q.projectId),
        signName: sig.name,
        signContact: sig.contact,
        createdAt: DateTime.fromMillisecondsSinceEpoch(q.createdAt),
      ));
      if (!ctx.mounted) return;
      Navigator.pop(ctx);
      messenger.showSnackBar(
        const SnackBar(content: Text('网页报价单已生成，选择应用即可发送给客户')),
      );
    } catch (e) {
      if (!ctx.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('分享网页报价单失败：$e')));
    }
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
    final editQuote = await showModalBottomSheet<Quote>(
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
                      extentRatio: 0.9,
                      children: [
                        CustomSlidableAction(
                          onPressed: (_) => _shareWeb(ctx, q),
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          child: const SlidableActionContent(
                              icon: Icons.public, label: '网页分享'),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) {
                            // 查看报价单详情（文本 + 参考图，参考图仅供查看）
                            showDialog<void>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: const Text('报价单详情'),
                                content: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(maxHeight: 320),
                                        child: SelectableText(_quoteTextFor(q)),
                                      ),
                                      if (q.imagePath.isNotEmpty) ...[
                                        const SizedBox(height: 16),
                                        const Text('参考图',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: AppTheme.textSub)),
                                        const SizedBox(height: 8),
                                        GestureDetector(
                                          onTap: () =>
                                              _viewImagePath(q.imagePath),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Image.file(
                                              File(q.imagePath),
                                              height: 200,
                                              width: double.infinity,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  const Text('图片已失效',
                                                      style: TextStyle(
                                                          color: AppTheme
                                                              .textSub)),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dctx),
                                      child: const Text('关闭')),
                                ],
                              ),
                            );
                          },
                          backgroundColor: Colors.blueGrey,
                          foregroundColor: Colors.white,
                          child: const SlidableActionContent(
                              icon: Icons.visibility_outlined, label: '查看'),
                        ),
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
                            // 关闭弹层并带回待编辑报价；等弹层动画结束后由 _openHistory
                            // 统一装载编辑态，从机制上避免与 TabBarView 动画并发导致 Tab 漂移。
                            Navigator.pop(ctx, q);
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
                                    ListTile(
                                      leading: const Icon(
                                          Icons.bookmarks_outlined,
                                          color: AppTheme.primary),
                                      title: const Text('另存为报价模板'),
                                      onTap: () => Navigator.pop(
                                          sctx, 'save_template'),
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
                            } else if (action == 'save_template') {
                              _saveAsTemplate(q);
                              if (!ctx.mounted) return;
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
                                content: Text('确定删除「${q.title}」吗？\n\n删除后该报价单将从历史与所有统计中移除，不可恢复。'),
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
                          // 关闭弹层并带回待编辑报价（同编辑 action，防 Tab 漂移）
                          Navigator.pop(ctx, q);
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
                                  _quoteStatusChip(ctx, q),
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
    // 弹层完全关闭后再装入编辑态（返回值非空 = 用户在历史里点了编辑/卡片）。
    // 彻底规避弹层关闭动画与 TabBarView 滚动动画并发导致的简单报价误切详细 Tab 竞态。
    if (editQuote != null && mounted) _openQuoteForEdit(editQuote);
  }

  // ================= v1.21.0 报价状态流转 =================
  Color _quoteStatusColor(QuoteStatus s) {
    switch (s) {
      case QuoteStatus.draft:
        return AppTheme.textSub;
      case QuoteStatus.sent:
        return AppTheme.accent;
      case QuoteStatus.confirmed:
        return Colors.blue;
      case QuoteStatus.deal:
        return Colors.green;
      case QuoteStatus.voided:
        return AppTheme.danger;
    }
  }

  IconData _quoteStatusIcon(QuoteStatus s) {
    switch (s) {
      case QuoteStatus.draft:
        return Icons.edit_note;
      case QuoteStatus.sent:
        return Icons.send_outlined;
      case QuoteStatus.confirmed:
        return Icons.thumb_up_alt_outlined;
      case QuoteStatus.deal:
        return Icons.check_circle_outline;
      case QuoteStatus.voided:
        return Icons.block;
    }
  }

  /// 历史列表中的状态标签；点击弹出快速状态切换。
  Widget _quoteStatusChip(BuildContext ctx, Quote q) {
    return GestureDetector(
      onTap: () async {
        final ns = await _quoteStatusPicker(ctx, q.status);
        if (ns == null || ns == q.status) return;
        await AppDb.instance.updateQuoteStatus(q.id!, ns);
        if (!ctx.mounted) return;
        // 关闭当前历史弹层并重建，让状态标签与统计即时刷新
        Navigator.pop(ctx);
        _openHistory();
      },
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: _quoteStatusColor(q.status).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_quoteStatusIcon(q.status),
                size: 12, color: _quoteStatusColor(q.status)),
            const SizedBox(width: 3),
            Text(
              q.status.label,
              style: TextStyle(
                fontSize: 11,
                color: _quoteStatusColor(q.status),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 报价状态快速切换选择器
  Future<QuoteStatus?> _quoteStatusPicker(
      BuildContext ctx, QuoteStatus current) {
    return showModalBottomSheet<QuoteStatus>(
      context: ctx,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('报价状态',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            for (final s in QuoteStatus.values)
              ListTile(
                leading: Icon(_quoteStatusIcon(s),
                    color: _quoteStatusColor(s)),
                title: Text(
                  s.label,
                  style: TextStyle(
                    fontWeight:
                        s == current ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                trailing:
                    s == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sctx, s),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ================= v1.21.0 报价模板 =================

  /// 把历史报价另存为模板（解绑客户/项目，仅保留明细/单价/税率/备注等）
  Future<void> _saveAsTemplate(Quote q) async {
    final ctrl = TextEditingController(text: '${q.title}（模板）');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('另存为报价模板'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '模板名称',
            hintText: '填写模板名称，之后可一键套用',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('保存模板'),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final t = Quote(
      title: name,
      taxRate: q.taxRate,
      lines: List.of(q.lines),
      total: q.total,
      createdAt: now,
      type: q.type,
      note: q.note,
      taxInclude: q.taxInclude,
      status: QuoteStatus.draft,
      isTemplate: true,
      updatedAt: now,
    );
    await AppDb.instance.insertQuote(t);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存为报价模板，可在报价页右上角「模板」中套用')),
    );
  }

  /// 打开模板列表：选择套用或删除模板
  Future<void> _openTemplateSheet() async {
    final templates = await AppDb.instance.getQuoteTemplates();
    if (!mounted) return;
    if (templates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有模板，可在报价历史中把报价「另存为模板」')),
      );
      return;
    }
    final picked = await showModalBottomSheet<Quote>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('报价模板',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('选择模板后自动填入，可修改后保存',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: templates.length,
                itemBuilder: (ctx, i) {
                  final t = templates[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    child: Card(
                      margin: EdgeInsets.zero,
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        onTap: () => Navigator.pop(ctx, t),
                        leading: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (t.isSimple
                                    ? AppTheme.primary
                                    : AppTheme.accent)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            t.isSimple ? '简单' : '详细',
                            style: TextStyle(
                              fontSize: 11,
                              color: t.isSimple
                                  ? AppTheme.primary
                                  : AppTheme.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        title: Text(t.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('¥${_fmt.format(t.total / 100)}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: AppTheme.danger),
                          tooltip: '删除模板',
                          onPressed: () async {
                            final messenger =
                                ScaffoldMessenger.of(ctx);
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: const Text('删除模板'),
                                content: Text(
                                    '确定删除模板「${t.title}」吗？删除后不可恢复。'),
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
                            if (ok != true || !ctx.mounted) return;
                            await AppDb.instance.deleteQuote(t.id!);
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            messenger.showSnackBar(
                                const SnackBar(content: Text('模板已删除')));
                            _openTemplateSheet();
                          },
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
    if (picked == null || !mounted) return;
    // 套用模板到新建编辑态（不覆盖任何历史）
    if (picked.isSimple) {
      _applySimpleTemplate(picked);
    } else {
      _applyDetailTemplate(picked);
    }
    _lockTabTo(picked.isSimple ? 0 : 1);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已套用模板，可修改后保存为新的报价单')),
    );
  }

  /// 模板套用到简单报价（全新编辑态）
  void _applySimpleTemplate(Quote t) {
    setState(() {
      _tabController.index = 0;
      _simpleQuoteId = null;
      _simpleCreatedAt = null;
      _simpleProjectId = null;
      _simpleCustomerId = null;
      _simpleNameCtrl.text = t.title;
      _simpleAmountCtrl.text = _numText(t.total / 100);
      _simpleNoteCtrl.text = t.note;
      _imagePath = t.imagePath;
      _simpleTaxRate = t.taxRate / 100;
      _simpleTaxCtrl.text = t.taxRate.toStringAsFixed(0);
    });
  }

  /// 模板套用到详细报价（全新编辑态）
  void _applyDetailTemplate(Quote t) {
    setState(() {
      _tabController.index = 1;
      _quoteId = null;
      _quoteCreatedAt = null;
      _projectId = null;
      _detailCustomerId = null;
      _titleCtrl.text = t.title;
      _clientCtrl.text = t.title;
      _taxRate = t.taxRate / 100;
      _taxCtrl.text = t.taxRate.toStringAsFixed(0);
      _detailNoteCtrl.text = t.note;
      _imagePath = t.imagePath;
      _lines
        ..clear()
        ..addAll(t.lines.isEmpty
            ? [
                const QuoteLine(
                    itemName: '设计服务',
                    hours: 8,
                    hourRate: AppConfig.defaultHourRate)
              ]
            : t.lines);
    });
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
      _imagePath = q.imagePath;
      _simpleTaxRate = q.taxRate / 100;
      _simpleTaxCtrl.text = q.taxRate.toStringAsFixed(0);
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
      _imagePath = q.imagePath;
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

  // v1.22.0：简单报价 Tab 改为可滚动容器，底部预留操作区高度，
  // 修复小屏手机上底部常驻按钮遮挡表单内容的问题；滚动即收起键盘，
  // 缓解键盘弹出导致的焦点错位。
  Widget _buildSimpleTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                inputFormatters: moneyInputFormatters,
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
          const SizedBox(height: 6),
          // 适用税率：v1.24.0 简单报价也可按单设置税率（仅记录并展示，一口价含税不重算总额）
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('适用税率',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSub)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _simpleTaxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: moneyInputFormatters,
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(
                      isDense: true,
                      suffixText: '%',
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                    ),
                    onChanged: (v) {
                      final n = double.tryParse(v);
                      setState(() => _simpleTaxRate = (n ?? 0) / 100);
                    },
                  ),
                ),
              ],
            ),
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
          const SizedBox(height: 12),
          _buildQuoteImageSection(),
        ],
    );
  }

  // ================= 详细报价 Tab（保留原有逻辑） =================
  Widget _buildDetailTab() {
    // v1.22.0：底部预留操作区高度，避免小屏上被常驻按钮遮挡；
    // 滚动即收起键盘，缓解表单焦点错位。
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                const SizedBox(height: 12),
                _buildQuoteImageSection(),
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
                    inputFormatters: moneyInputFormatters,
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
            onPressed: _openTemplateSheet,
            icon: const Icon(Icons.bookmarks_outlined, size: 18),
            label: const Text('模板'),
          ),
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
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: moneyInputFormatters,
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
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: moneyInputFormatters,
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
