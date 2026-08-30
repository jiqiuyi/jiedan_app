// ============================================================
// 收款 / 提现通道统一入口（真实支付接入点预留）
// ============================================================
// 【当前状态】MVP 阶段：
//   - 收款：个人微信/支付宝收款码展示 + 手动确认登记（QrCodePayChannel）
//   - 提现：申请登记 + 人工打款（ManualWithdrawChannel）
//
// 【接入真实收款时，只需在这里做三件事】（哥哥拿到商户资质后）：
//   1. 新增一个实现 PayChannel 的真实通道类（如 WechatAppPayChannel），
//      填入商户号 mchId、API 密钥 apiKey、证书路径，实现 createPayment / query。
//   2. 新增一个实现 WithdrawChannel 的真实提现类（如 WechatTransferChannel），
//      调用官方转账 API（微信商家转账 / 支付宝转账 / 银行代付）。
//   3. 把下方 [Channels.pay] / [Channels.withdraw] 换成真实实现。
// 业务页面一律只面向 Channels 编程，通道切换无需改任何页面。
// ============================================================

import '../models.dart';

/// 收款请求
class PaymentRequest {
  final String orderId; // 本地订单号（可用时间戳）
  final double amount; // 金额（元）
  final String title; // 收款标题/项目名
  const PaymentRequest({
    required this.orderId,
    required this.amount,
    required this.title,
  });
}

/// 收款结果
class PaymentResult {
  final bool ok;
  final String message; // 提示给用户
  final String? refNo; // 支付平台流水号（真实通道回调后填写）
  const PaymentResult(this.ok, this.message, {this.refNo});
}

/// 提现请求
class WithdrawRequest {
  final double amount; // 金额（元）
  final WithdrawMethod method; // 方式
  final String accountName; // 收款人姓名
  final String accountNo; // 收款账号
  const WithdrawRequest({
    required this.amount,
    required this.method,
    required this.accountName,
    required this.accountNo,
  });
}

/// 提现结果
class WithdrawResult {
  final bool ok;
  final String message;
  const WithdrawResult(this.ok, this.message);
}

/// ---------- 收款通道接口 ----------
/// 真实微信/支付宝商户接入后，实现本接口并替换 [Channels.pay]。
abstract class PayChannel {
  String get name;

  /// 发起收款。返回给用户的展示/结果信息。
  Future<PaymentResult> createPayment(PaymentRequest req);

  /// 查询订单状态（真实通道接入后轮询/回调使用）。
  /// 调用方：手动确认到账流程（项目收款 show_payment_code.dart 的 _confirm、
  /// 钱包充值到账确认）会先调用本方法查询订单状态；MVP 手动模式直接返回
  /// "无需查询"，真实通道接入后此处返回平台查单结果，页面据此提示用户。
  Future<PaymentResult> query(PaymentRequest req);
}

/// ---------- 提现通道接口 ----------
/// 真实打款（微信商家转账 / 支付宝转账 / 银行代付）接入后实现并替换 [Channels.withdraw]。
abstract class WithdrawChannel {
  String get name;

  /// 发起提现打款。返回结果。
  Future<WithdrawResult> withdraw(WithdrawRequest req);
}

/// MVP 收款通道：个人收款码 + 手动确认。
/// 业务方先展示收款码，用户在微信/支付宝付款后，在 App 内手动登记到账。
class QrCodePayChannel implements PayChannel {
  @override
  String get name => '个人收款码（手动确认）';

  @override
  Future<PaymentResult> createPayment(PaymentRequest req) async {
    // 真实接入点①：这里改为拉起微信 APP 支付 / 支付宝 APP 支付，
    // 或调用服务商（虎皮椒 / PAYJS 等）下单接口换取支付参数。
    return const PaymentResult(true, '请出示收款码收款，到账后手动确认登记');
  }

  @override
  Future<PaymentResult> query(PaymentRequest req) async {
    // 真实接入点②：微信/支付宝查单接口，或服务商查单接口。
    return const PaymentResult(false, '手动确认模式下无需查询，到账后手动登记即可');
  }
}

/// MVP 提现通道：申请登记 + 人工打款。
/// 打款完成后由人工/后台将记录标记为「已提现」。
class ManualWithdrawChannel implements WithdrawChannel {
  @override
  String get name => '人工打款';

  @override
  Future<WithdrawResult> withdraw(WithdrawRequest req) async {
    // 真实接入点③：这里改为调用微信商家转账 / 支付宝转账 / 银行代付 API，
    // 打款成功后返回 ok，并自动更新提现记录状态为 done。
    return const WithdrawResult(true, '提现申请已提交，待人工核对打款');
  }
}

/// ---------- 充值通道接口 ----------
/// 余额充值（用户向平台付款）接入后实现并替换 [Channels.recharge]。
abstract class RechargeChannel {
  String get name;

  /// 发起充值（生成收款信息 / 拉起支付）。返回给用户的展示/结果信息。
  Future<PaymentResult> createRecharge(PaymentRequest req);
}

/// MVP 充值通道：个人收款码 + 手动确认到账。
/// 用户向平台收款码付款后，在 App 内手动确认，余额入账。
class QrCodeRechargeChannel implements RechargeChannel {
  @override
  String get name => '个人收款码（手动确认）';

  @override
  Future<PaymentResult> createRecharge(PaymentRequest req) async {
    // 真实接入点④：这里改为拉起微信/支付宝 APP 支付，或服务商下单接口。
    return const PaymentResult(true, '请向收款码付款，到账后手动确认入账');
  }
}

/// ---------- 全局通道注册表 ----------
/// 拿到真实商户资质后，仅需改动这里几行。
class Channels {
  static PayChannel pay = QrCodePayChannel();
  static RechargeChannel recharge = QrCodeRechargeChannel();
  static WithdrawChannel withdraw = ManualWithdrawChannel();
}
