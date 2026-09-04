import 'package:flutter/services.dart';

/// 金额输入格式器：只允许合法金额字符与结构（v1.19.1 起统一用于所有金额输入框）。
///
/// 规则：
/// - 仅保留数字与小数点，负号 / 字母 / 空格等一律过滤；
/// - 多个小数点只保留第一个（如 "1.2.3" → "1.23"）；
/// - 小数位最多两位（精确到分，如 "12.345" → "12.34"）；
/// - 支持输入中间态：孤立小数点自动补零（"." → "0."，"..5" → "0.5"）。
///
/// 通过 text 校验即可保证进入保存流程的金额字符串合法（非负、最多两位小数），
/// 与 [Money.parseYuanToFen] 配合避免多小数点 / 负号 / 超长小数等异常金额落库。
class MoneyInputFormatter extends TextInputFormatter {
  const MoneyInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    // 1. 过滤非法字符（数字或小数点之外的字符全部剔除，含负号）
    var text = newValue.text.replaceAll(RegExp(r'[^0-9.]'), '');
    // 2. 处理小数点：仅保留第一个，小数位最多两位
    final dotIndex = text.indexOf('.');
    if (dotIndex >= 0) {
      final intPart = text.substring(0, dotIndex);
      var fracPart = text.substring(dotIndex + 1).replaceAll('.', '');
      if (fracPart.length > 2) fracPart = fracPart.substring(0, 2);
      if (intPart.isEmpty && fracPart.isEmpty) {
        // 只剩孤立小数点："." / ".." -> 清理为空
        text = '';
      } else if (intPart.isEmpty) {
        // ".5" -> "0.5"
        text = '0.$fracPart';
      } else {
        text = '$intPart.$fracPart';
      }
    }
    if (text == newValue.text) return newValue;
    // 输入中间态既有内容被改写时，把光标放到末尾，保证继续输入不出错
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// 统一的金额输入格式化列表（报价 / 收款 / 充值 / 提现 / 项目约定金额等共用）。
final List<TextInputFormatter> moneyInputFormatters = const [
  MoneyInputFormatter(),
];
