import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../constants.dart';
import '../models.dart';
import '../theme.dart';

/// 网页版报价单分享数据（从已保存的 Quote 组装，与 App 内展示一致）。
class QuoteWebData {
  final Quote quote; // 已保存的报价（简单 / 详细，含明细 / 税率 / 状态 / 参考图）
  final String customerName; // 客户名称
  final String projectName; // 关联项目（可选）
  final String signName; // 落款名称（个人 / 工作室）
  final String signContact; // 落款联系方式
  final DateTime createdAt; // 报价创建时间

  const QuoteWebData({
    required this.quote,
    required this.customerName,
    this.projectName = '',
    this.signName = '',
    this.signContact = '',
    required this.createdAt,
  });

  bool get isSimple => quote.isSimple;

  /// 明细合计（分），仅详细报价使用。
  int get subtotal =>
      quote.lines.fold<int>(0, (s, l) => s + l.laborCost + l.materialFee);

  /// 税费（分），税率 = quote.taxRate（百分比）。
  int get tax => (subtotal * quote.taxRate / 100).round();

  String get currencyText => NumberFormat('#,##0.00').format(quote.total / 100);

  /// 报价编号：BP-YYYYMMDD-XXX（与 PDF 导出保持一致）。
  String get number {
    final s = (createdAt.millisecondsSinceEpoch % 1000).toString().padLeft(3, '0');
    return 'BP-${createdAt.year}${createdAt.month.toString().padLeft(2, '0')}'
        '${createdAt.day.toString().padLeft(2, '0')}-$s';
  }
}

/// 网页报价单生成与分享服务（v1.25.0 杀手级功能「可分享网页报价单」）：
/// - 在本地生成一份自包含 HTML 报价页（内联样式，手机浏览器自适应）；
/// - 通过系统分享面板发给客户（微信 / QQ / 邮件等），不通网络、不上传服务器；
/// - 展示内容与 App 内报价详情一致：客户 / 项目 / 编号 / 日期、明细表格、
///   单价数量金额、税率、合计、落款、状态标签；
/// - 预留云端托管接口结构（hostedUrl），后续可接入服务器短链，不做上传。
class QuoteWebService {
  QuoteWebService._();

  /// 生成自包含 HTML 报价页并保存到本地，随后拉起系统分享面板。
  /// 返回 true 表示成功拉起分享；失败抛出异常由调用方提示。
  static Future<void> share(QuoteWebData data) async {
    final html = buildHtml(data);
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}${Platform.pathSeparator}quote_web');
    if (!folder.existsSync()) folder.createSync(recursive: true);
    final date = DateFormat('yyyy-MM-dd')
        .format(DateTime.fromMillisecondsSinceEpoch(data.quote.createdAt));
    final fileName = '报价单_${_safeFileName(data.quote.title)}_$date.html';
    final file = File('${folder.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(html, flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/html')],
      subject: '报价单 · ${data.quote.title}',
      text: '报价单 · ${data.quote.title}',
    );
  }

  static String _safeFileName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    return cleaned.isEmpty ? '报价' : cleaned;
  }

  /// ==================== 云端托管预留接口结构（未来版本） ====================
  /// 后续如需客户通过服务器链接在浏览器查看（无需发文件），在此实现：
  ///   1) 调用 [buildHtml] 得到 HTML 文本；
  ///   2) 由云端接口接收并存储，返回带 token 的短链（如 `https://host/q/<id>`）；
  ///   3) 本地持久化「报价 id -> 短链」映射，App 内直接展示链接；
  ///   4) 分享入口从「发文件」升级为「发链接」（复用系统分享）。
  /// 当前版本未接入服务器，统一返回 null（仅本地 HTML 分享，业务数据不上传）。
  static Future<String?> hostedUrl(QuoteWebData data) async => null;

  // ==================== HTML 生成 ====================

  static String buildHtml(QuoteWebData data) {
    final q = data.quote;
    final primary = _hex(AppTheme.primary);
    final textSub = _hex(AppTheme.textSub);
    final imageHtml = _inlineImageHtml(q.imagePath);
    final statusColor = _statusHex(q.status);
    final isSimple = data.isSimple;
    final linesHtml = isSimple ? '' : _linesTableHtml(data);
    final amountHtml = isSimple ? _simpleAmountHtml(data) : _amountHtml(data);
    final noteHtml = q.note.trim().isEmpty
        ? ''
        : '<section class="note"><h3>备注</h3><p>${_esc(q.note.trim())}</p></section>';
    final signHtml =
        (data.signName.isEmpty && data.signContact.isEmpty)
            ? ''
            : '<section class="sign"><p class="sign-name">${_esc(data.signName)}</p>'
                '${data.signContact.isEmpty ? '' : '<p class="sign-contact">${_esc(data.signContact)}</p>'}'
                '<div class="sign-line"></div></section>';

    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<meta name="format-detection" content="telephone=no">
<title>报价单 · ${_esc(q.title)}</title>
<style>
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{background:#eef1f6;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue","Microsoft YaHei",sans-serif;color:#333;line-height:1.5}
.page{max-width:720px;margin:16px auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 14px rgba(31,45,61,.08)}
.brand{height:4px;background:$primary}
.head{padding:22px 22px 4px}
.brand-row{display:flex;justify-content:space-between;align-items:flex-start}
.brand-row h1{font-size:22px;font-weight:700;color:$primary}
.meta{font-size:12px;color:$textSub;text-align:right;line-height:1.7}
.title{padding:14px 22px 0}
.title h2{font-size:16px;font-weight:700}
.title .sub{font-size:11px;color:$textSub;margin-top:3px}
.info{padding:14px 22px 0}
.info-table{width:100%;border-collapse:collapse;border:1px solid #e3e7ee;border-radius:6px;overflow:hidden;font-size:13px}
.info-table th{background:$primary;color:#fff;font-weight:600;padding:7px 8px;text-align:left}
.info-table td{padding:7px 8px;border-top:1px solid #eef1f6;color:#444}
.info-table td.c{text-align:center;color:$textSub}
.badge{display:inline-flex;align-items:center;gap:4px;font-size:12px;font-weight:600;padding:3px 9px;border-radius:999px;color:$statusColor;background:${statusColor}22;margin-left:8px;vertical-align:middle}
.lines{padding:14px 22px 0}
.lines h3{font-size:13px;font-weight:700;color:#555;margin-bottom:8px}
table.det{width:100%;border-collapse:collapse;font-size:13px}
table.det th{background:#f4f6fa;color:#666;font-weight:600;padding:8px;text-align:left;border-bottom:1px solid #e3e7ee}
table.det td{padding:8px;border-bottom:1px solid #f0f2f7}
table.det td.num{text-align:right;font-variant-numeric:tabular-nums}
table.det td.center{text-align:center;color:$textSub}
table.det tr:last-child td{border-bottom:none}
.amount{padding:14px 22px 0}
.amount-box{width:100%;max-width:380px;margin-left:auto;background:#f7f9fc;border:1px solid #e3e7ee;border-radius:6px;padding:12px 14px;font-size:13px;color:#444}
.amount-row{display:flex;justify-content:space-between;padding:3px 0}
.amount-row.total{border-top:1px dashed #d4dae6;margin-top:6px;padding-top:8px;font-weight:700;color:#333}
.amount-row.total .val{font-size:18px;font-weight:700;color:$primary}
.amount-row .val{font-variant-numeric:tabular-nums}
.simple-amount{max-width:380px;margin-left:auto;background:#f7f9fc;border:1px solid #e3e7ee;border-radius:6px;padding:12px 18px}
.simple-amount .label{font-size:13px;font-weight:700;color:#555}
.simple-amount .val{font-size:22px;font-weight:700;color:$primary;margin-top:4px;font-variant-numeric:tabular-nums}
.simple-amount .tax{font-size:11px;color:$textSub;margin-top:3px}
.refimg{padding:14px 22px 0}
.refimg img{width:100%;border-radius:8px;border:1px solid #eef1f6}
.note{padding:14px 22px 0}
.note h3{font-size:13px;font-weight:700;color:#555;margin-bottom:6px}
.note p{font-size:13px;color:#555;white-space:pre-wrap}
.sign{padding:26px 22px 18px;text-align:right}
.sign-name{font-size:14px;font-weight:700;color:#444}
.sign-contact{font-size:12px;color:$textSub;margin-top:3px}
.sign-line{width:150px;height:1px;background:$primary;margin:6px 0 0 auto}
.foot{padding:10px 22px 16px;text-align:center;font-size:10.5px;color:#a6adbb;border-top:1px solid #f0f2f7;margin-top:18px}
</style>
</head>
<body>
<div class="page">
  <div class="brand"></div>
  <div class="head">
    <div class="brand-row">
      <h1>报价单</h1>
      <div class="meta">编号 ${_esc(data.number)}<br>日期 ${_esc(DateFormat('yyyy-MM-dd').format(data.createdAt))}</div>
    </div>
  </div>
  <div class="title">
    <h2>${_esc(q.title)}<span class="badge">${_esc(q.status.label)}</span></h2>
    <div class="sub">${isSimple ? '一口价报价' : '详细报价'}</div>
  </div>
  <div class="info">
    <table class="info-table">
      <tr><th>客户</th><td>${_esc(data.customerName)}</td><th>关联项目</th><td>${_esc(data.projectName.isEmpty ? '-' : data.projectName)}</td></tr>
    </table>
  </div>
  $linesHtml
  $amountHtml
  $imageHtml
  $noteHtml
  $signHtml
  <div class="foot">本报价单由「接单管家」生成 · 如有疑问请联系我方</div>
</div>
</body>
</html>
''';
  }

  static String _linesTableHtml(QuoteWebData data) {
    final rows = StringBuffer();
    var idx = 1;
    for (final l in data.quote.lines) {
      final item = l.itemName.isEmpty ? '（未命名项目）' : _esc(l.itemName);
      if (l.hours > 0 || l.hourRate > 0) {
        rows.write('<tr><td class="center">$idx</td><td>$item</td>'
            '<td class="num">${_num(l.hours)}</td>'
            '<td class="num">¥${_money(l.hourRate)}</td>'
            '<td class="num">¥${_money(l.materialFee)}</td>'
            '<td class="num">¥${_money(l.laborCost + l.materialFee)}</td></tr>');
      } else {
        rows.write('<tr><td class="center">$idx</td><td>$item</td>'
            '<td class="center">-</td><td class="center">-</td>'
            '<td class="num">¥${_money(l.materialFee)}</td>'
            '<td class="num">¥${_money(l.materialFee)}</td></tr>');
      }
      idx++;
    }
    return '''
      <div class="lines">
        <h3>报价明细</h3>
        <table class="det">
          <tr><th style="width:34px">序号</th><th>项目名称</th><th style="width:64px">工时</th><th style="width:84px">单价</th><th style="width:88px">物料费</th><th style="width:96px">小计</th></tr>
          $rows
        </table>
      </div>''';
  }

  static String _amountHtml(QuoteWebData data) {
    final rate =
        data.quote.taxRate > 0 ? '税费（${data.quote.taxRate.toStringAsFixed(1)}%）' : '税费';
    return '''
      <div class="amount">
        <div class="amount-box">
          <div class="amount-row"><span>费用小计</span><span class="val">¥${_money(data.subtotal)}</span></div>
          <div class="amount-row"><span>$rate</span><span class="val">¥${_money(data.tax)}</span></div>
          <div class="amount-row total"><span>本次报价合计</span><span class="val">¥${data.currencyText}</span></div>
        </div>
      </div>''';
  }

  static String _simpleAmountHtml(QuoteWebData data) {
    final taxNote =
        data.quote.taxRate > 0
            ? '（含税，税率 ${data.quote.taxRate.toStringAsFixed(0)}%）'
            : '';
    return '''
      <div class="amount">
        <div class="simple-amount">
          <div class="label">报价金额</div>
          <div class="val">¥${data.currencyText}</div>
          ${taxNote.isEmpty ? '' : '<div class="tax">$taxNote</div>'}
        </div>
      </div>''';
  }

  /// 参考图以内联 base64 嵌入 HTML（自包含、离线可看、不上传）。
  static String _inlineImageHtml(String imagePath) {
    if (imagePath.isEmpty) return '';
    try {
      final f = File(imagePath);
      if (!f.existsSync()) return '';
      final bytes = f.readAsBytesSync();
      final mime = _mimeOf(imagePath);
      final b64 = base64Encode(bytes);
      return '<div class="refimg"><img alt="参考图" src="data:$mime;base64,$b64"></div>';
    } catch (_) {
      // 图片读取失败不影响报价页主体
      return '';
    }
  }

  static String _mimeOf(String path) {
    final ext = path.toLowerCase();
    if (ext.endsWith('.jpg') || ext.endsWith('.jpeg')) return 'image/jpeg';
    if (ext.endsWith('.png')) return 'image/png';
    if (ext.endsWith('.webp')) return 'image/webp';
    if (ext.endsWith('.gif')) return 'image/gif';
    if (ext.endsWith('.bmp')) return 'image/bmp';
    return 'image/png';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static String _hex(Color c) {
    final argb = c.toARGB32();
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  static String _statusHex(QuoteStatus s) {
    switch (s) {
      case QuoteStatus.draft:
        return _hex(AppTheme.textSub);
      case QuoteStatus.sent:
        return _hex(AppTheme.accent);
      case QuoteStatus.confirmed:
        return '#1976d2';
      case QuoteStatus.deal:
        return '#2e7d32';
      case QuoteStatus.voided:
        return _hex(AppTheme.danger);
    }
  }

  static String _money(int fen) => NumberFormat('#,##0.00').format(fen / 100);

  static String _num(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}
