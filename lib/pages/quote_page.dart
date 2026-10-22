import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
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
import '../services/error_reporter.dart';
import '../utils/money_input.dart';
import '../widgets/app_ui.dart';

/// 报价页 AppBar 右侧图标区总宽度（3 × 40 + 4 = 124）。
/// 标题居中时用作左侧空白占位宽度，保证「报价单」在全宽中绝对居中。
const double _kAppBarSideWidth = 124;

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
  // v1.43.3：明细行不再预填任何实值，默认给一行空白明细（仅灰色占位提示）
  final _lines = <QuoteLine>[QuoteLine(itemName: '')];
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
    // 三态兜底：DB 异常不冒泡（报价页表单仍可手填），项目下拉为空不影响出单。
    try {
      final list = await AppDb.instance.getProjects();
      final customers = await AppDb.instance.getCustomers();
      if (!mounted) return;
      setState(() {
        _projects = list;
        _customers = customers;
      });
    } catch (e, st) {
      ErrorReporter.instance.logError('quote_load_projects', e, st);
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
        SnackBar(content: Text(L10n.instance.t('quote_ref_added'))),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_ref_save_failed'))),
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
            errorBuilder: (_, _, _) => Padding(
              padding: EdgeInsets.all(32),
              child: Text(L10n.instance.t('quote_page_image_expired'),
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
        Text(L10n.instance.t('quote_page_reference_image'),
            style: TextStyle(fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
        SizedBox(height: 4),
        Text(L10n.instance.t('quote_ref_desc'),
            style: TextStyle(fontSize: 11, color: AppTheme.textSub)),
        SizedBox(height: 8),
        if (_imagePath.isNotEmpty)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: _viewQuoteImage,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
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
                      child: Icon(Icons.broken_image_outlined, color: AppTheme.textSub),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextButton.icon(
                    onPressed: _viewQuoteImage,
                    icon: Icon(Icons.zoom_in, size: 18),
                    label: Text(L10n.instance.t('quote_view_full')),
                  ),
                  TextButton.icon(
                    onPressed: _removeQuoteImage,
                    icon: Icon(Icons.delete_outline, size: 18),
                    label: Text(L10n.instance.t('common_remove')),
                  ),
                ],
              ),
            ],
          )
        else
          OutlinedButton.icon(
            onPressed: _pickQuoteImage,
            icon: Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: Text(L10n.instance.t('quote_pick_ref_image')),
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
      ..writeln(L10n.instance.t('i18n_054'))
      ..writeln(L10n.instance.t('i18n_231', args: {'v0': objectName}))
      ..writeln(L10n.instance.t('i18n_351', args: {'v0': _fmt.format(amount)}));
    if (note.isNotEmpty) {
      b.writeln(L10n.instance.t('i18n_201', args: {'v0': note}));
    }
    return b.toString();
  }

  Future<void> _copySimpleToClipboard() async {
    await Clipboard.setData(ClipboardData(text: buildSimpleQuoteText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('quote_copied_tip'))),
    );
  }

  // ================= 简单报价：保存 =================
  Future<void> _saveSimpleQuote() async {
    final objectName = _simpleObjectName;
    if (objectName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_target_required'))),
      );
      return;
    }
    final amount = double.tryParse(_simpleAmountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_amount_required'))),
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
      lines: [],
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
      SnackBar(content: Text(_simpleQuoteId == null ? L10n.instance.t('quote_saved') : L10n.instance.t('quote_updated'))),
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
      ..writeln(L10n.instance.t('i18n_055'))
      ..writeln(L10n.instance.t('quote_client_line', args: {'v0': _clientCtrl.text.trim().isEmpty ? '________' : _clientCtrl.text.trim()}));
    b.writeln('------------------');
    for (int i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      b.writeln('${i + 1}. ${l.itemName}');
      if (l.hours > 0) {
        b.writeln(L10n.instance.t('i18n_001', args: {'v0':l.hours.toString(), 'v1':_fmt.format(l.hourRate / 100), 'v2':_fmt.format(l.laborCost / 100)}));
      }
      if (l.materialFee > 0) {
        b.writeln(L10n.instance.t('i18n_002', args: {'v0': _fmt.format(l.materialFee / 100)}));
      }
    }
    b.writeln('------------------');
    b.writeln(L10n.instance.t('i18n_246', args: {'v0': _fmt.format(_subtotal / 100)}));
    b.writeln(L10n.instance.t('i18n_513', args: {'v0': (_taxRate * 100).toStringAsFixed(0), 'v1': _fmt.format(_tax / 100)}));
    b.writeln(L10n.instance.t('i18n_166', args: {'v0': _fmt.format(_total / 100)}));
    b.writeln(L10n.instance.t('i18n_581'));
    return b.toString();
  }

  Future<void> _copyToClipboard() async {
    await Clipboard.setData(ClipboardData(text: buildQuoteText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('quote_copied_tip'))),
    );
  }

  // ================= 详细报价：保存（保留原逻辑 + 备注/类型） =================
  Future<void> _saveQuote() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_title_required'))),
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
      SnackBar(content: Text(_quoteId == null ? L10n.instance.t('quote_saved') : L10n.instance.t('quote_updated'))),
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
        ..add(QuoteLine(itemName: '')); // v1.43.3：重置为一行空白明细，不预填实值
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
      // v1.46.13：简单报价税率带入详细报价（q.taxRate 存百分数），不再重置为默认值
      _taxRate = q.taxRate / 100;
      _taxCtrl.text = q.taxRate > 0 ? q.taxRate.toStringAsFixed(0) : '';
      _detailNoteCtrl.text = q.note;
      // 金额自动生成一行明细：项目名=报价对象名、工时=1、单价=报价金额
      _lines
        ..clear()
        ..add(QuoteLine(itemName: q.title, hours: 1, hourRate: q.total));
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('quote_to_detailed_done'))),
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

  /// 第17批：基于 quote_id 精确联动——从报价单查看已收流水与已收合计。
  Future<void> _showQuoteFlows(Quote q) async {
    final id = q.id;
    if (id == null) return;
    final total = await AppDb.instance.quotePaidTotal(id);
    final flows = await AppDb.instance.paymentsByQuote(id);
    if (!mounted) return;
    final fmt = NumberFormat('#,##0.00');
    await showAppSheet<void>(
      context,
      builder: (sctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.receipt_long_outlined,
                  color: AppTheme.primary),
              title: Text(L10n.instance.t('i18n_281', args: {'v0': fmt.format(total / 100)}),
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              subtitle: Text(L10n.instance.t('quote_page_quote', args: {'q.title': q.title}),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            AppCardDivider(),
            Flexible(
              child: flows.isEmpty
                  ? AppEmpty(
                      icon: Icons.receipt_long_outlined,
                      title: L10n.instance.t('quote_no_payments'),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: flows.length,
                      separatorBuilder: (_, _) =>
                          AppCardDivider(),
                      itemBuilder: (_, i) {
                        final f = flows[i];
                        final amt =
                            ((f['amount'] as num?)?.toInt() ?? 0);
                        final t =
                            ((f['type'] as num?)?.toInt() ?? 0);
                        final fl =
                            ((f['type_label'] as String?)?.trim() ?? '');
                        final typeName = fl.isNotEmpty
                            ? fl
                            : (t >= 0 && t < PayType.values.length
                                ? PayType.values[t].label
                                : L10n.instance.t('quote_page_collect'));
                        final paidAt = DateTime.fromMillisecondsSinceEpoch(
                            ((f['paid_at'] as num?)?.toInt() ?? 0));
                        final note =
                            ((f['note'] as String?)?.trim() ?? '');
                        final reconciled =
                            ((f['reconciled'] as num?)?.toInt() ?? 0) == 1;
                        return ListTile(
                          dense: true,
                          title: Text(
                              '+${fmt.format(amt / 100)}  $typeName'
                              '${note.isEmpty ? '' : '  ·  $note'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          trailing: Text(
                              reconciled ? L10n.instance.t('quote_page_reconciled') : L10n.instance.t('quote_page_unreconciled'),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: reconciled
                                      ? AppTheme.accent
                                      : AppTheme.warn)),
                          subtitle: Text(
                              DateFormat('yyyy-MM-dd HH:mm').format(paidAt)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
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
          title: Text(L10n.instance.t('quote_close_deal_choose')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.instance.t('quote_to_project_desc', args: {'quoteTitle':quoteTitle}),
                  style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
              SizedBox(height: 12),
              if (customers.isNotEmpty) ...[
                DropdownButtonFormField<int>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: InputDecoration(
                      isDense: true, labelText: L10n.instance.t('i18n_284')),
                  items: customers
                      .map((c) => DropdownMenuItem<int>(
                          value: c.id!, child: Text(c.name)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    selected = v;
                    nameCtrl.clear();
                  }),
                ),
                SizedBox(height: 12),
                AppCardDivider(),
                Text(L10n.instance.t('quote_or_new_customer'),
                    style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
                SizedBox(height: 6),
              ],
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: L10n.instance.t('quote_new_customer_name'),
                ),
                onChanged: (v) => setState(() {
                  if (v.trim().isNotEmpty) selected = null;
                }),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: Text(L10n.instance.t('common_cancel'))),
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
              child: Text(L10n.instance.t('quote_close_deal')),
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
        SnackBar(content: Text(L10n.instance.t('quote_web_generated'))),
      );
    } catch (e) {
      if (!ctx.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(L10n.instance.t('quote_web_share_failed', args: {'e':'$e'}))));
    }
  }

  // ================= 历史弹层 =================
  Future<void> _openHistory() async {
    // 三态兜底：DB 读取失败不得让历史弹层一直转圈/无反应，
    // 直接提示「加载失败」并返回（用户可再次点击重试）。
    final List<Quote> quotes;
    try {
      quotes = await AppDb.instance.getQuotes();
    } catch (e, st) {
      ErrorReporter.instance.logError('quote_open_history', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('quote_history_load_failed'))),
        );
      }
      return;
    }
    if (!mounted) return;
    if (quotes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_history_empty'))),
      );
      return;
    }
    final editQuote = await showAppSheet<Quote>(
      context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        builder: (ctx, scrollCtrl) => ClipRRect(
          // v1.46.12：裁剪弹层顶部圆角，杜绝 Slidable 操作区绘制超出白色弹层
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.sheet)),
          child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(14),
              child: Text(L10n.instance.t('quote_history'),
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
                      motion: ScrollMotion(),
                      // v1.46.12：操作区收窄，确保全部按钮完整落在白色弹层内
                      extentRatio: 0.7,
                      children: [
                        CustomSlidableAction(
                          onPressed: (_) => _shareWeb(ctx, q),
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          // 首项左圆角（验收口径：首左末右、中间直角）
                          borderRadius: const BorderRadius.horizontal(
                              left: Radius.circular(AppRadius.md)),
                          child: SlidableActionContent(
                              icon: Icons.public, label: L10n.instance.t('quote_web_share')),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) {
                            // 查看报价单详情（文本 + 参考图，参考图仅供查看）
                            showDialog<void>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: Text(L10n.instance.t('quote_detail')),
                                content: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ConstrainedBox(
                                        constraints:
                                            BoxConstraints(maxHeight: 320),
                                        child: SelectableText(_quoteTextFor(q)),
                                      ),
                                      if (q.imagePath.isNotEmpty) ...[
                                        SizedBox(height: 16),
                                        Text(L10n.instance.t('quote_reference_image'),
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: AppTheme.textSub)),
                                        SizedBox(height: 8),
                                        GestureDetector(
                                          onTap: () =>
                                              _viewImagePath(q.imagePath),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(AppRadius.sm),
                                            child: Image.file(
                                              File(q.imagePath),
                                              height: 200,
                                              width: double.infinity,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Text(L10n.instance.t('quote_image_expired'),
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
                                      child: Text(L10n.instance.t('common_close'))),
                                ],
                              ),
                            );
                          },
                          backgroundColor: Colors.blueGrey,
                          foregroundColor: Colors.white,
                          child: SlidableActionContent(
                              icon: Icons.visibility_outlined, label: L10n.instance.t('common_view')),
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
                              SnackBar(content: Text(L10n.instance.t('quote_page_quote_text'))),
                            );
                          },
                          backgroundColor: AppTheme.accent,
                          foregroundColor: Colors.white,
                          child: SlidableActionContent(
                              icon: Icons.content_copy, label: L10n.instance.t('common_copy')),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) {
                            // 关闭弹层并带回待编辑报价；等弹层动画结束后由 _openHistory
                            // 统一装载编辑态，从机制上避免与 TabBarView 动画并发导致 Tab 漂移。
                            Navigator.pop(ctx, q);
                          },
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          child: SlidableActionContent(
                              icon: Icons.edit_outlined, label: L10n.instance.t('common_edit')),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            final action = await showAppSheet<String>(
                              ctx,
                              builder: (sctx) => SafeArea(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: Icon(
                                          Icons.account_balance_wallet_outlined,
                                          color: AppTheme.accent),
                                      title: Text(L10n.instance.t('quote_view_payments')),
                                      onTap: () =>
                                          Navigator.pop(sctx, 'pay_flows'),
                                    ),
                                    ListTile(
                                      leading: Icon(Icons.trending_up,
                                          color: AppTheme.accent),
                                      title: Text(L10n.instance.t('quote_mark_pending')),
                                      onTap: () =>
                                          Navigator.pop(sctx, 'to_pending'),
                                    ),
                                    ListTile(
                                      leading: Icon(Icons.assignment_outlined,
                                          color: AppTheme.primary),
                                      title: Text(L10n.instance.t('quote_close_deal_btn')),
                                      onTap: () =>
                                          Navigator.pop(sctx, 'to_project'),
                                    ),
                                    if (q.isSimple)
                                      ListTile(
                                        leading: Icon(Icons.unfold_more,
                                            color: AppTheme.accent),
                                        title: Text(L10n.instance.t('quote_to_detailed')),
                                        onTap: () =>
                                            Navigator.pop(sctx, 'to_full'),
                                      ),
                                    ListTile(
                                      leading: Icon(
                                          Icons.bookmarks_outlined,
                                          color: AppTheme.primary),
                                      title: Text(L10n.instance.t('quote_save_template_btn')),
                                      onTap: () => Navigator.pop(
                                          sctx, 'save_template'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                            if (action == null || !ctx.mounted) return;
                            if (action == 'pay_flows') {
                              await _showQuoteFlows(q);
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                            } else if (action == 'to_pending') {
                              await _quoteToPendingCollection(q);
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                              messenger.showSnackBar(SnackBar(
                                  content: Text(L10n.instance.t('quote_mark_pending_done'))));
                            } else if (action == 'to_project') {
                              final projectId = await _quoteToProject(q);
                              if (projectId == null || !ctx.mounted) return;
                              Navigator.pop(ctx);
                              messenger.showSnackBar(SnackBar(
                                  content: Text(L10n.instance.t('quote_close_done'))));
                            } else if (action == 'to_full') {
                              _convertToFull(q);
                              Navigator.pop(ctx);
                            } else if (action == 'save_template') {
                              // v1.46.12：先等模板保存弹窗交互完成再关历史弹层，
                              // 避免弹窗 push 与历史弹层 pop 动画并发导致保存确认丢失
                              await _saveAsTemplate(q);
                              if (!ctx.mounted) return;
                              Navigator.pop(ctx);
                            }
                          },
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          child: SlidableActionContent(
                              icon: Icons.swap_horiz, label: L10n.instance.t('quote_flow')),
                        ),
                        CustomSlidableAction(
                          onPressed: (_) async {
                            final messenger =
                                ScaffoldMessenger.of(context);
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: Text(L10n.instance.t('quote_delete')),
                                content: Text(L10n.instance.t('i18n_501', args: {'v0': q.title})),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dctx, false),
                                      child: Text(L10n.instance.t('common_cancel'))),
                                  AppButton(
                                    label: L10n.instance.t('common_delete'),
                                    kind: AppButtonKind.danger,
                                    size: AppButtonSize.medium,
                                    expand: false,
                                    onPressed: () =>
                                        Navigator.pop(dctx, true),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            await AppDb.instance.deleteQuote(q.id!);
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(content: Text(L10n.instance.t('quote_deleted'))),
                            );
                            _openHistory();
                          },
                          backgroundColor: AppTheme.danger,
                          foregroundColor: Colors.white,
                          borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(AppRadius.md)),
                          child: SlidableActionContent(
                              icon: Icons.delete_outline, label: L10n.instance.t('common_delete')),
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
                                      borderRadius: BorderRadius.circular(AppRadius.xs),
                                    ),
                                    child: Text(
                                      q.isSimple ? L10n.instance.t('quote_simple') : L10n.instance.t('quote_detailed'),
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
                              SizedBox(height: 8),
                              Text(
                                '¥${_fmt.format(q.total / 100)}',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 2),
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
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_quoteStatusIcon(q.status),
                size: 12, color: _quoteStatusColor(q.status)),
            SizedBox(width: 3),
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
    return showAppSheet<QuoteStatus>(
      ctx,
      builder: (sctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(14),
              child: AppSheetHeader(title: L10n.instance.t('quote_status')),
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
                    s == current ? Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sctx, s),
              ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ================= v1.21.0 报价模板 =================

  /// 把历史报价另存为模板（解绑客户/项目，仅保留明细/单价/税率/备注等）
  Future<void> _saveAsTemplate(Quote q) async {
    final ctrl = TextEditingController(text: L10n.instance.t('quote_page_template', args: {'q.title': q.title}));
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(L10n.instance.t('quote_save_template_btn')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: L10n.instance.t('i18n_471'),
            hintText: L10n.instance.t('quote_template_name_hint'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(L10n.instance.t('quote_save_template')),
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
      SnackBar(content: Text(L10n.instance.t('quote_template_saved'))),
    );
  }

  /// 打开模板列表：选择套用或删除模板
  Future<void> _openTemplateSheet() async {
    // 三态兜底：DB 读取失败提示「加载失败」，不静默无反应。
    final List<Quote> templates;
    try {
      templates = await AppDb.instance.getQuoteTemplates();
    } catch (e, st) {
      ErrorReporter.instance.logError('quote_open_template', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('quote_template_load_failed'))),
        );
      }
      return;
    }
    if (!mounted) return;
    if (templates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_template_empty'))),
      );
      return;
    }
    final picked = await showAppSheet<Quote>(
      context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            Padding(
              padding: EdgeInsets.all(14),
              child: Text(L10n.instance.t('quote_templates'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(L10n.instance.t('quote_template_desc'),
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
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                          ),
                          child: Text(
                            t.isSimple ? L10n.instance.t('i18n_521') : L10n.instance.t('i18n_565'),
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
                          icon: Icon(Icons.delete_outline,
                              color: AppTheme.danger),
                          tooltip: L10n.instance.t('quote_delete_template'),
                          onPressed: () async {
                            final messenger =
                                ScaffoldMessenger.of(ctx);
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: Text(L10n.instance.t('quote_delete_template')),
                                content: Text(
                                    L10n.instance.t('i18n_504', args: {'v0': t.title})),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dctx, false),
                                      child: Text(L10n.instance.t('common_cancel'))),
                                  AppButton(
                                    label: L10n.instance.t('common_delete'),
                                    kind: AppButtonKind.danger,
                                    size: AppButtonSize.medium,
                                    expand: false,
                                    onPressed: () =>
                                        Navigator.pop(dctx, true),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true || !ctx.mounted) return;
                            await AppDb.instance.deleteQuote(t.id!);
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            messenger.showSnackBar(
                                SnackBar(content: Text(L10n.instance.t('quote_template_deleted'))));
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
      SnackBar(content: Text(L10n.instance.t('quote_template_applied'))),
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
            ? [QuoteLine(itemName: '')] // v1.43.3：模板无明细时给一行空白明细
            : t.lines);
    });
  }

  /// 按历史报价单生成文本（不依赖当前编辑态），简单/详细分别处理
  String _quoteTextFor(Quote q) {
    if (q.isSimple) {
      final b = StringBuffer()
        ..writeln(L10n.instance.t('i18n_054'))
        ..writeln(L10n.instance.t('i18n_233', args: {'v0': q.title}));
      b.writeln(L10n.instance.t('i18n_352', args: {'v0': _fmt.format(q.total / 100)}));
      // v1.46.12：简单报价带出税率（含税一口价的价内税费）
      if (q.taxRate > 0) {
        final rate = q.taxRate / 100;
        final taxFen = (q.total * rate / (1 + rate)).round();
        b.writeln(
            L10n.instance.t('i18n_511', args: {'v0': q.taxRate.toStringAsFixed(0), 'v1': _fmt.format(taxFen / 100)}));
      }
      if (q.note.trim().isNotEmpty) {
        b.writeln(L10n.instance.t('i18n_202', args: {'v0': q.note.trim()}));
      }
      return b.toString();
    }
    final sub = q.lines.fold<double>(
        0, (s, l) => s + l.laborCost + l.materialFee);
    final tax = sub * (q.taxRate / 100);
    final b = StringBuffer()
      ..writeln(L10n.instance.t('i18n_055'))
      ..writeln(L10n.instance.t('i18n_233', args: {'v0': q.title}));
    b.writeln('------------------');
    for (int i = 0; i < q.lines.length; i++) {
      final l = q.lines[i];
      b.writeln('${i + 1}. ${l.itemName}');
      if (l.hours > 0) {
        b.writeln(L10n.instance.t('i18n_001', args: {'v0':l.hours.toString(), 'v1':_fmt.format(l.hourRate / 100), 'v2':_fmt.format(l.laborCost / 100)}));
      }
      if (l.materialFee > 0) {
        b.writeln(L10n.instance.t('i18n_002', args: {'v0': _fmt.format(l.materialFee / 100)}));
      }
    }
    b.writeln('------------------');
    b.writeln(L10n.instance.t('i18n_247', args: {'v0': _fmt.format(sub / 100)}));
    b.writeln(L10n.instance.t('i18n_516', args: {'v0': q.taxRate.toStringAsFixed(0), 'v1': _fmt.format(tax / 100)}));
    b.writeln(L10n.instance.t('i18n_167', args: {'v0': _fmt.format(q.total / 100)}));
    b.writeln(L10n.instance.t('i18n_581'));
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
            ? [QuoteLine(itemName: '')] // v1.43.3：历史无明细时给一行空白明细
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
    // v1.39.1：恢复可滚动表单（小屏 / 键盘弹起 / 内容超高时可上下滑动），
    // 各字段按自然顺序自上而下排列（金额输入紧随关联客户之后），
    // 去掉原 Spacer / spaceBetween——无界高度下它们会把内容撑开或挤压到错误位置。
    return LayoutBuilder(
      builder: (context, constraints) {
        final double minH = (constraints.maxHeight.isFinite &&
                constraints.maxHeight > 24)
            ? constraints.maxHeight - 24
            : 0.0;
        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minH),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                // —— 上段：报价对象 / 关联项目 / 关联客户档案 ——
                Column(
                  children: [
                    Text(L10n.instance.t('quote_target'),
                        style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSub,
                            fontWeight: FontWeight.w500)),
                    SizedBox(height: 8),
                    TextField(
                      controller: _simpleNameCtrl,
                      decoration: InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: L10n.instance.t('quote_target_hint'),
                      ),
                    ),
                    SizedBox(height: 8),
                    // 关联项目：轻量入口 + 底部弹层选择（v1.12.0 改，替代原丑下拉）
                    InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: _pickSimpleProject,
                      child: InputDecorator(
                        decoration: InputDecoration(
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
                                    ? L10n.instance.t('quote_link_project_optional')
                                    : _projects
                                            .firstWhere(
                                                (p) => p.id == _simpleProjectId)
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
                                onTap: () =>
                                    setState(() => _simpleProjectId = null),
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
                    SizedBox(height: 8),
                    // 关联客户档案：轻量入口 + 底部弹层选择
                    InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: _pickSimpleCustomer,
                      child: InputDecorator(
                        decoration: InputDecoration(
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
                                    ? L10n.instance.t('i18n_132')
                                    : _customers
                                            .firstWhere(
                                                (c) => c.id == _simpleCustomerId)
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
                                onTap: () =>
                                    setState(() => _simpleCustomerId = null),
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
                  ],
                ),
                SizedBox(height: 16),
                // —— 中段：大号报价总额输入框 ——
                Column(
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: (MediaQuery.sizeOf(context).width * 0.66)
                              .clamp(280.0, 480.0),
                        ),
                        child: TextField(
                          controller: _simpleAmountCtrl,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
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
                    SizedBox(height: 8),
                    Center(
                      child: Text(L10n.instance.t('quote_total_label'),
                          style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
                    ),
                    SizedBox(height: 6),
                    // 适用税率：v1.24.0 简单报价也可按单设置税率（仅记录并展示，一口价含税不重算总额）
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(L10n.instance.t('quote_tax_label'),
                              style:
                                  TextStyle(fontSize: 12, color: AppTheme.textSub)),
                          SizedBox(width: 8),
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
                  ],
                ),
                SizedBox(height: 16),
                // —— 下段：备注 / 参考图 ——
                Column(
                  children: [
                    Text(L10n.instance.t('common_note_optional'),
                        style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSub,
                            fontWeight: FontWeight.w500)),
                    SizedBox(height: 6),
                    SizedBox(
                      height: 72,
                      child: TextField(
                        controller: _simpleNoteCtrl,
                        maxLines: null,
                        expands: true,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: L10n.instance.t('quote_notes_hint'),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    SizedBox(height: 12),
                    _buildQuoteImageSection(),
                  ],
                ),
              ],
            ),
          ),
        );
      },
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
                Text(L10n.instance.t('quote_title_label'),
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                SizedBox(height: 6),
                TextField(
                  controller: _titleCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: L10n.instance.t('quote_title_example'),
                  ),
                ),
                SizedBox(height: 12),
                Text(L10n.instance.t('quote_customer_name'),
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                SizedBox(height: 6),
                TextField(
                  controller: _clientCtrl,
                  decoration: InputDecoration(isDense: true, border: OutlineInputBorder()),
                ),
                SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: _detailCustomerId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: L10n.instance.t('i18n_132'),
                  ),
                  items: [
                    DropdownMenuItem<int?>(
                        value: null, child: Text(L10n.instance.t('quote_no_link'))),
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
                SizedBox(height: 12),
                Text(L10n.instance.t('quote_link_project_optional'),
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                SizedBox(height: 6),
                DropdownButtonFormField<int?>(
                  initialValue: _projectId,
                  isExpanded: true,
                  decoration: InputDecoration(isDense: true),
                  items: [
                    DropdownMenuItem<int?>(
                        value: null, child: Text(L10n.instance.t('quote_no_link_project'))),
                    ..._projects.map((pr) => DropdownMenuItem<int?>(
                        value: pr.id, child: Text(pr.title))),
                  ],
                  onChanged: (v) => setState(() => _projectId = v),
                ),
                SizedBox(height: 12),
                Text(L10n.instance.t('common_note_optional'),
                    style: TextStyle(
                        fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                SizedBox(height: 6),
                TextField(
                  controller: _detailNoteCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: L10n.instance.t('quote_notes_optional'),
                  ),
                ),
                SizedBox(height: 12),
                _buildQuoteImageSection(),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          child: Row(
            children: [
              Expanded(child: Text(L10n.instance.t('quote_line_items'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              TextButton.icon(
                onPressed: () => setState(() => _lines.add(QuoteLine(itemName: ''))),
                icon: Icon(Icons.add, size: 18),
                label: Text(L10n.instance.t('quote_add_line')),
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
                Text(L10n.instance.t('quote_tax')),
                Spacer(),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _taxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: moneyInputFormatters,
                    textAlign: TextAlign.right,
                    decoration: InputDecoration(
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
                _row(L10n.instance.t('i18n_588'), '¥${_fmt.format(_subtotal / 100)}', Colors.white70),
                _row(L10n.instance.t('i18n_512'), '¥${_fmt.format(_tax / 100)}', Colors.white70),
                Divider(color: Colors.white24),
                _row(L10n.instance.t('quote_pdf_total'), '¥${_fmt.format(_total / 100)}', Colors.white, bold: true, big: true),
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
        title: Text(L10n.instance.t('quote_signature')),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L10n.instance.t('i18n_420'),
                style: TextStyle(color: AppTheme.textSub, fontSize: 12),
              ),
              SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: L10n.instance.t('i18n_549'),
                  hintText: L10n.instance.t('quote_signature_example'),
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: contactCtrl,
                decoration: InputDecoration(
                  labelText: L10n.instance.t('i18n_542'),
                  hintText: L10n.instance.t('quote_signature_contact'),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.instance.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_save')),
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
        SnackBar(content: Text(L10n.instance.t('quote_signature_saved'))),
      );
    }
  }

  Future<void> _exportSimplePdf() async {
    final objectName = _simpleObjectName;
    if (objectName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_target_required'))),
      );
      return;
    }
    final amount = double.tryParse(_simpleAmountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_amount_required'))),
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
        SnackBar(content: Text(L10n.instance.t('quote_target_required2'))),
      );
      return;
    }
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('quote_items_required'))),
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
      builder: (_) => Dialog(
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
              Text(L10n.instance.t('quote_generating_pdf')),
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
        SnackBar(content: Text(L10n.instance.t('quote_pdf_failed', args: {'e':'$e'}))),
      );
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  /// AppBar 右上角图标按钮：固定 40×40 紧凑点击区，
  /// 三个按钮总宽与左侧占位宽度 [_kAppBarSideWidth] 对齐。
  Widget _appBarIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        iconSize: 22,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          minimumSize: Size(40, 40),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
        ),
        icon: Icon(icon),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 标题居中：无返回按钮时左侧留出与右侧图标区等宽的空白占位，
        // 使「报价单」始终位于整条 AppBar 的水平中心。
        title: Text(L10n.instance.t('quote_title')),
        centerTitle: true,
        leadingWidth: _kAppBarSideWidth,
        leading: Navigator.of(context).canPop() ? null : const SizedBox.shrink(),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSub,
          indicatorColor: AppTheme.primary,
          tabs: [
            Tab(text: L10n.instance.t('quote_simple')),
            Tab(text: L10n.instance.t('quote_detailed')),
          ],
        ),
        actions: [
          _appBarIcon(
            icon: Icons.article_outlined,
            tooltip: L10n.instance.t('common_template'),
            onPressed: _openTemplateSheet,
          ),
          _appBarIcon(
            icon: Icons.draw_outlined,
            tooltip: L10n.instance.t('common_signature'),
            onPressed: _editSignature,
          ),
          _appBarIcon(
            icon: Icons.history,
            tooltip: L10n.instance.t('common_history'),
            onPressed: _openHistory,
          ),
          SizedBox(width: 4),
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
                    child: AppButton(
                      label: L10n.instance.t('quote_generate_copy'),
                      kind: AppButtonKind.primary,
                      size: AppButtonSize.medium,
                      expand: false,
                      onPressed:
                          isSimple ? _copySimpleToClipboard : _copyToClipboard,
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: AppButton(
                      label: isSimple
                          ? (_simpleQuoteId == null ? L10n.instance.t('i18n_115') : L10n.instance.t('i18n_429'))
                          : (_quoteId == null ? L10n.instance.t('i18n_115') : L10n.instance.t('i18n_429')),
                      kind: AppButtonKind.tonal,
                      size: AppButtonSize.medium,
                      expand: false,
                      onPressed: isSimple ? _saveSimpleQuote : _saveQuote,
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: AppButton(
                      label: L10n.instance.t('quote_export_pdf'),
                      kind: AppButtonKind.tonal,
                      size: AppButtonSize.medium,
                      expand: false,
                      onPressed: isSimple ? _exportSimplePdf : _exportFullPdf,
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
          Spacer(),
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
        style: TextStyle(fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500),
      );

  InputDecoration _dec() => InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        border: OutlineInputBorder(),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: AppTheme.textSub.withValues(alpha: 0.35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: AppTheme.primary, width: 1.5),
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
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel(L10n.instance.t('i18n_631')),
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
                    icon: Icon(Icons.close, size: 18, color: AppTheme.textSub),
                  ),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel(L10n.instance.t('i18n_252')),
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
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel(L10n.instance.t('i18n_154')),
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
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel(L10n.instance.t('i18n_489')),
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
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
                color: Color(0xFFE4E7EF),
                borderRadius: BorderRadius.circular(AppRadius.xxs),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(L10n.instance.t('quote_link_project'),
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textMain)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Text(L10n.instance.t('quote_link_project_hint'),
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
          ),
          AppCardDivider(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(Icons.block,
                      size: 20, color: AppTheme.textSub),
                  title: Text(L10n.instance.t('quote_no_link'),
                      style: TextStyle(color: AppTheme.textSub)),
                  trailing: selectedId == null
                      ? Icon(Icons.check,
                          size: 18, color: AppTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, -1),
                ),
                if (!hasProjects)
                  AppEmpty(
                    icon: Icons.folder_open_outlined,
                    title: L10n.instance.t('quote_no_project'),
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
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
                color: Color(0xFFE4E7EF),
                borderRadius: BorderRadius.circular(AppRadius.xxs),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(L10n.instance.t('quote_link_customer'),
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textMain)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Text(L10n.instance.t('quote_link_customer_hint'),
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
          ),
          AppCardDivider(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(Icons.block,
                      size: 20, color: AppTheme.textSub),
                  title: Text(L10n.instance.t('quote_no_link'),
                      style: TextStyle(color: AppTheme.textSub)),
                  trailing: selectedId == null
                      ? const Icon(Icons.check,
                          size: 18, color: AppTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, -1),
                ),
                if (!hasCustomers)
                  AppEmpty(
                    icon: Icons.people_outline,
                    title: L10n.instance.t('quote_no_customer'),
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
