import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../theme.dart';
import '../models.dart';
import '../database.dart';

/// 报价计算与报价单管理（v7 起支持落库历史）：
/// - 计算报价 → 复制文本发给客户；
/// - 保存报价单（可关联项目）→ 历史列表可重新打开编辑、复制、删除。
class QuotePage extends StatefulWidget {
  /// 从项目详情进入时预选关联项目
  final int? initialProjectId;
  final String? initialTitle;

  const QuotePage({super.key, this.initialProjectId, this.initialTitle});

  @override
  State<QuotePage> createState() => _QuotePageState();
}

class _QuotePageState extends State<QuotePage> {
  final _lines = <QuoteLine>[
    const QuoteLine(itemName: '设计服务', hours: 8, hourRate: AppConfig.defaultHourRate),
  ];
  double _taxRate = AppConfig.defaultTaxRate;
  final _fmt = NumberFormat('#,##0.00');
  final _clientCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  int? _quoteId; // 当前编辑的历史报价单 id（null=新建）
  int? _projectId; // 关联项目
  List<Project> _projects = [];

  double get _subtotal =>
      _lines.fold(0, (sum, l) => sum + l.laborCost + l.materialFee);
  double get _tax => _subtotal * _taxRate;
  double get _total => _subtotal + _tax;

  @override
  void initState() {
    super.initState();
    _titleCtrl.text = widget.initialTitle ?? '';
    _projectId = widget.initialProjectId;
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final list = await AppDb.instance.getProjects();
    if (mounted) setState(() => _projects = list);
  }

  @override
  void dispose() {
    _clientCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  String buildQuoteText() {
    final b = StringBuffer()
      ..writeln('【报价单】')
      ..writeln('客户：${_clientCtrl.text.trim().isEmpty ? '________' : _clientCtrl.text.trim()}');
    b.writeln('------------------');
    for (int i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      b.writeln('${i + 1}. ${l.itemName}');
      if (l.hours > 0) {
        b.writeln('   工时 ${l.hours}h × ${_fmt.format(l.hourRate)}元/h = ${_fmt.format(l.laborCost)}元');
      }
      if (l.materialFee > 0) {
        b.writeln('   物料 ${_fmt.format(l.materialFee)}元');
      }
    }
    b.writeln('------------------');
    b.writeln('小计：${_fmt.format(_subtotal)} 元');
    b.writeln('税费（${(_taxRate * 100).toStringAsFixed(0)}%）：${_fmt.format(_tax)} 元');
    b.writeln('合计：${_fmt.format(_total)} 元');
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

  /// 落库保存（新建 / 更新当前编辑的历史报价单）
  Future<void> _saveQuote() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写报价单标题（如客户 / 项目名）')),
      );
      return;
    }
    if (_quoteId == null) {
      await AppDb.instance.insertQuote(Quote(
        projectId: _projectId,
        title: title,
        taxRate: _taxRate * 100, // 模型存百分比
        lines: List.of(_lines),
        total: double.parse(_total.toStringAsFixed(2)),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    } else {
      await AppDb.instance.updateQuote(Quote(
        id: _quoteId,
        projectId: _projectId,
        title: title,
        taxRate: _taxRate * 100,
        lines: List.of(_lines),
        total: double.parse(_total.toStringAsFixed(2)),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_quoteId == null ? '报价单已保存到历史' : '报价单已更新')),
    );
  }

  /// 报价历史弹层：查看 / 重新打开编辑 / 复制 / 删除
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
                    leading: const Icon(Icons.description_outlined,
                        color: AppTheme.primary),
                    title: Text(q.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '¥${_fmt.format(q.total)} · ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(q.createdAt))}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                            _loadQuote(q);
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

  /// 按历史报价单生成文本（不依赖当前编辑态）
  String _quoteTextFor(Quote q) {
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
        b.writeln('   工时 ${l.hours}h × ${_fmt.format(l.hourRate)}元/h = ${_fmt.format(l.laborCost)}元');
      }
      if (l.materialFee > 0) {
        b.writeln('   物料 ${_fmt.format(l.materialFee)}元');
      }
    }
    b.writeln('------------------');
    b.writeln('小计：${_fmt.format(sub)} 元');
    b.writeln('税费（${q.taxRate.toStringAsFixed(0)}%）：${_fmt.format(tax)} 元');
    b.writeln('合计：${_fmt.format(q.total)} 元');
    b.writeln('请确认无误后回复，感谢合作！');
    return b.toString();
  }

  /// 把历史报价单载入编辑态
  void _loadQuote(Quote q) {
    setState(() {
      _quoteId = q.id;
      _titleCtrl.text = q.title;
      _projectId = q.projectId;
      _taxRate = q.taxRate / 100;
      _lines
        ..clear()
        ..addAll(q.lines.isEmpty
            ? [const QuoteLine(itemName: '设计服务', hours: 8, hourRate: AppConfig.defaultHourRate)]
            : q.lines);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('报价单'),
        actions: [
          TextButton.icon(
            onPressed: _openHistory,
            icon: const Icon(Icons.history, size: 18),
            label: const Text('历史'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
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
                  _row('费用小计', '¥${_fmt.format(_subtotal)}', Colors.white70),
                  _row('税费', '¥${_fmt.format(_tax)}', Colors.white70),
                  const Divider(color: Colors.white24),
                  _row('本次报价合计', '¥${_fmt.format(_total)}', Colors.white, bold: true, big: true),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _copyToClipboard,
                    icon: const Icon(Icons.content_copy),
                    label: const Text('生成并复制'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _saveQuote,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_quoteId == null ? '保存到历史' : '更新保存'),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    _rateCtrl = TextEditingController(text: widget.line.hourRate == 0 ? '' : widget.line.hourRate.toString());
    _matCtrl = TextEditingController(text: widget.line.materialFee == 0 ? '' : widget.line.materialFee.toString());
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
        hourRate: double.tryParse(_rateCtrl.text.trim()) ?? 0,
        materialFee: double.tryParse(_matCtrl.text.trim()) ?? 0,
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
