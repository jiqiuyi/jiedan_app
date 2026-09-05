import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../theme.dart';

/// 报价单 PDF 导出数据（从 UI 状态组装，PDF 专属字段与落款一并带上）。
class QuotePdfData {
  final String title; // 报价名称
  final String type; // 'simple' | 'full'
  final int total; // 报价合计（单位：分）
  final double subtotal; // 费用小计（分，仅详细报价）
  final double tax; // 税费（分，仅详细报价）
  final double taxRate; // 税率（小数，仅详细报价）
  final List<QuoteLine> lines; // 报价明细（仅详细报价）
  final String note; // 备注
  final String customerName; // 客户 / 报价对象
  final String projectName; // 关联项目（可选）
  final int createdAt; // 创建时间戳（毫秒）
  final String signName; // 落款名称（个人 / 工作室）
  final String signContact; // 落款联系方式

  const QuotePdfData({
    required this.title,
    required this.type,
    required this.total,
    this.subtotal = 0,
    this.tax = 0,
    this.taxRate = 0,
    this.lines = const [],
    this.note = '',
    this.customerName = '',
    this.projectName = '',
    required this.createdAt,
    this.signName = '',
    this.signContact = '',
  });

  String get currencyText => NumberFormat('#,##0.00').format(total / 100);
}

/// 报价单 PDF 导出服务：
/// - 简单 / 详细报价统一走此服务，输出一份可打印 / 可分享的 PDF 报价单；
/// - 内置中文字体（assets/fonts/simhei.ttf），适配系统 PDF 阅读器；
/// - 生成后调用系统分享面板（可存文件 / 发微信等）。
class QuotePdfService {
  QuotePdfService._();

  // ---- 落款：个人 / 工作室名称与联系方式（本地持久化，导出时自动带上） ----
  static const String _kSignName = 'quote_pdf_sign_name';
  static const String _kSignContact = 'quote_pdf_sign_contact';

  /// 读取已保存的落款信息（不设置过则返回空串）。
  static Future<({String name, String contact})> readSignature() async {
    final sp = await SharedPreferences.getInstance();
    return (
      name: sp.getString(_kSignName) ?? '',
      contact: sp.getString(_kSignContact) ?? '',
    );
  }

  /// 保存落款信息，供后续导出 PDF 复用。
  static Future<void> saveSignature({
    required String name,
    required String contact,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kSignName, name.trim());
    await sp.setString(_kSignContact, contact.trim());
  }

  static const String _assetFont = 'assets/fonts/simhei.ttf';

  static pw.Font? _cnFont;

  static Future<pw.Font> _font() async {
    if (_cnFont != null) return _cnFont!;
    final data = await rootBundle.load(_assetFont);
    _cnFont = pw.Font.ttf(data);
    return _cnFont!;
  }

  /// 生成 PDF 并拉起系统分享（含保存到文件）。
  static Future<void> export(BuildContext context, QuotePdfData data) async {
    final cn = await _font();
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: cn, bold: cn),
    );

    final number = _quoteNumber(data.createdAt);
    final date = DateFormat('yyyy-MM-dd')
        .format(DateTime.fromMillisecondsSinceEpoch(data.createdAt));

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(34),
        header: (ctx) => _buildHeader(data, number, date),
        footer: (ctx) => _buildFooter(ctx),
        build: (ctx) => [
          // 基本信息区
          _infoBlock(data, number, date),
          pw.SizedBox(height: 18),
          if (data.type == 'full' && data.lines.isNotEmpty) ...[
            _linesTable(data),
            pw.SizedBox(height: 14),
            _amountBlock(data),
          ] else
            _simpleAmountBlock(data),
          if (data.note.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            _noteBlock(data.note),
          ],
          if (data.signName.isNotEmpty || data.signContact.isNotEmpty) ...[
            pw.SizedBox(height: 28),
            _signBlock(data),
          ],
        ],
      ),
    );

    final bytes = await doc.save();
    await Printing.sharePdf(
      bytes: bytes,
      filename: '报价单_${safeFileName(data.title)}_$date.pdf',
    );
  }

  static String safeFileName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    return cleaned.isEmpty ? '报价' : cleaned;
  }

  static String _quoteNumber(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    final seq = (ts % 1000).toString().padLeft(3, '0');
    return 'BP-${d.year}${d.month.toString().padLeft(2, '0')}'
        '${d.day.toString().padLeft(2, '0')}-$seq';
  }

  static pw.Widget _brandColorLine(PdfColor c) =>
      pw.Container(height: 4, color: c);

  static pw.Widget _buildHeader(QuotePdfData data, String number, String date) {
    final primary = PdfColor.fromInt(AppTheme.primary.toARGB32());
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('报价单',
                style: pw.TextStyle(
                    fontSize: 22, fontWeight: pw.FontWeight.bold, color: primary)),
            pw.Text('编号 $number\n日期 $date',
                textAlign: pw.TextAlign.right,
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          ],
        ),
        pw.SizedBox(height: 8),
        _brandColorLine(primary),
        pw.SizedBox(height: 14),
        pw.Text(data.title,
            style: pw.TextStyle(
                fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(
          data.type == 'simple' ? '一口价报价' : '详细报价',
          style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
        ),
        pw.SizedBox(height: 12),
      ],
    );
  }

  static pw.Widget _infoBlock(QuotePdfData data, String number, String date) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.TableHelper.fromTextArray(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.4),
        headers: ['客户', '关联项目', '编号', '报价日期'],
        data: [
          [data.customerName.isEmpty ? '-' : data.customerName,
           data.projectName.isEmpty ? '-' : data.projectName, number, date],
        ],
        headerStyle: pw.TextStyle(
            fontSize: 9,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold),
        headerDecoration: pw.BoxDecoration(color: PdfColor.fromInt(AppTheme.primary.toARGB32())),
        cellStyle: const pw.TextStyle(fontSize: 10),
        cellAlignments: {
          0: pw.Alignment.centerLeft,
          1: pw.Alignment.centerLeft,
          2: pw.Alignment.center,
          3: pw.Alignment.center,
        },
      ),
    );
  }

  static pw.Widget _linesTable(QuotePdfData data) {
    // 明细表跨页防切断（第18批）：
    // - 表头行 TableRow(repeat: true) → 明细表跨页时表头在每一页顶部重复；
    // - 每个明细行为独立 TableRow → pdf Table 跨页按整行切分，行不被分页拦腰切断。
    final rows = <pw.TableRow>[
      pw.TableRow(
        repeat: true,
        decoration: pw.BoxDecoration(
          color: PdfColor.fromInt(AppTheme.primary.toARGB32()),
        ),
        children: [
          for (final h in ['序号', '项目名称', '工时', '单价', '物料费', '小计'])
            _tableCell(
              h,
              align: pw.Alignment.center,
              style: const pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold),
            ),
        ],
      ),
    ];

    const colAligns = [
      pw.Alignment.center,
      pw.Alignment.centerLeft,
      pw.Alignment.center,
      pw.Alignment.centerRight,
      pw.Alignment.centerRight,
      pw.Alignment.centerRight,
    ];
    var idx = 1;
    for (final l in data.lines) {
      final item = l.itemName.isEmpty ? '（未命名项目）' : l.itemName;
      final cells = l.hours > 0 || l.hourRate > 0
          ? [
              '$idx',
              item,
              _num(l.hours),
              '¥${_money(l.hourRate)}',
              '¥${_money(l.materialFee)}',
              '¥${_money(l.hours * l.hourRate + l.materialFee)}',
            ]
          : ['$idx', item, '-', '-', '¥${_money(l.materialFee)}', '¥${_money(l.materialFee)}'];
      rows.add(pw.TableRow(
        children: [
          for (var i = 0; i < cells.length; i++)
            _tableCell(
              cells[i],
              align: colAligns[i],
              style: const pw.TextStyle(fontSize: 10),
            ),
        ],
      ));
      idx++;
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.4),
      columnWidths: {
        0: const pw.FixedColumnWidth(26),
        1: const pw.FlexColumnWidth(),
        2: const pw.FixedColumnWidth(50),
        3: const pw.FixedColumnWidth(70),
        4: const pw.FixedColumnWidth(70),
        5: const pw.FixedColumnWidth(80),
      },
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
      children: rows,
    );
  }

  static pw.Widget _tableCell(
    String text, {
    required pw.Alignment align,
    required pw.TextStyle style,
  }) {
    return pw.Align(
      alignment: align,
      child: pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: pw.Text(text, style: style),
      ),
    );
  }

  static pw.Widget _amountBlock(QuotePdfData data) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [
        pw.Container(
          width: 260,
          padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: pw.BoxDecoration(
            color: PdfColors.blueGrey50,
            border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              _moneyRow('费用小计', '¥${_money(data.subtotal)}'),
              _moneyRow('税费（${(data.taxRate * 100).toStringAsFixed(1)}%）',
                  '¥${_money(data.tax)}'),
              pw.Divider(color: PdfColors.grey400, height: 8),
              pw.Row(
                children: [
                  pw.Text('本次报价合计',
                      style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                  pw.Spacer(),
                  pw.Text(data.currencyText,
                      style: pw.TextStyle(
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromInt(AppTheme.primary.toARGB32()))),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _simpleAmountBlock(QuotePdfData data) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: pw.BoxDecoration(
        color: PdfColors.blueGrey50,
        border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Row(
        children: [
          pw.Text('报价金额', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Spacer(),
          pw.Text(data.currencyText,
              style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromInt(AppTheme.primary.toARGB32()))),
        ],
      ),
    );
  }

  static pw.Widget _noteBlock(String note) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('备注',
              style: pw.TextStyle(
                  fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
          pw.SizedBox(height: 4),
          pw.Text(note, style: const pw.TextStyle(fontSize: 10, height: 1.5)),
        ],
      ),
    );
  }

  static pw.Widget _signBlock(QuotePdfData data) {
    final primary = PdfColor.fromInt(AppTheme.primary.toARGB32());
    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(data.signName,
              style: pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold)),
          if (data.signContact.isNotEmpty) ...[
            pw.SizedBox(height: 3),
            pw.Text(data.signContact,
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          ],
          pw.SizedBox(height: 4),
          pw.Container(
            width: 140,
            height: 0.8,
            color: primary,
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildFooter(pw.Context ctx) {
    // 页脚微调（第18批）：页码随 MultiPage 连续累加（第 x / n 页），
    // 加大上下内边距并收紧行距（height 1.2），保证页脚不浮出页面下边界。
    return pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 12),
      padding: const pw.EdgeInsets.only(top: 8, bottom: 2),
      decoration: pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
      ),
      child: pw.Text(
        '第 ${ctx.pageNumber} / ${ctx.pagesCount} 页   ·   接单管家 出品',
        style: pw.TextStyle(
            fontSize: 9, color: PdfColors.grey600, height: 1.2),
      ),
    );
  }

  static pw.Widget _moneyRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
          pw.Spacer(),
          pw.Text(value, style: const pw.TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  static String _money(num fen) => NumberFormat('#,##0.00').format(fen / 100);

  static String _num(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}
