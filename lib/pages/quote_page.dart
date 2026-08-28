import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../theme.dart';
import '../models.dart';

class QuotePage extends StatefulWidget {
  const QuotePage({super.key});

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

  double get _subtotal =>
      _lines.fold(0, (sum, l) => sum + l.laborCost + l.materialFee);
  double get _tax => _subtotal * _taxRate;
  double get _total => _subtotal + _tax;

  @override
  void dispose() {
    _clientCtrl.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('报价计算')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('客户名称',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSub, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _clientCtrl,
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
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
              child: Column(
                children: [
                  Row(
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
            child: FilledButton.icon(
              onPressed: _copyToClipboard,
              icon: const Icon(Icons.content_copy),
              label: const Text('生成报价单并复制'),
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
