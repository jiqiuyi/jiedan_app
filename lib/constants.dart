// ============================================================
// 接单管家 - 全局约束参数（硬编码基线）
// 修改产品策略时，只需改动本文件，勿散落各处。
// ============================================================
class AppConfig {
  // ---- 应用基础 ----
  static const String appName = '接单管家';
  static const String version = '1.10.0';

  // ---- 云端后端 ----
  // 账号 / 订阅 / 订单 / 推广数据均走云端；业务数据（客户/项目/收款）仍存本地。
  static const String apiBaseUrl = 'http://121.41.97.109:8090';

  // ---- 免费版额度（达到上限后触发付费引导）----
  static const int freeCustomerLimit = 1; // 免费版客户上限
  static const int freeProjectLimit = 3; // 免费版活跃项目上限

  // ---- 订阅定价（仅展示用，MVP 阶段支付网关未接入）----
  // 首月特惠 1 元，仅限首次开通、每人一次；之后按标准价。
  static const double firstMonthPrice = 1; // 首月特惠价（元，仅一次）
  static const double monthlyPrice = 10; // 月订阅价（元，首月之后）
  static const double yearlyPrice = 68; // 年订阅价（元）
  static const double foreverPrice = 98; // 永久订阅价（元，一次买断）

  // ---- 报价默认参数 ----
  // 默认工时单价（分/小时）。v9 金额统一改分为整数存储后，此处同步为分。
  static const int defaultHourRate = 15000; // 150 元/小时 = 15000 分
  // 默认综合税率：未填写税率时按 0 计算，不自动计税（用户可自行填写）
  static const double defaultTaxRate = 0;

  // ---- 数据库 ----
  static const String dbName = 'jiedan_guanjia.db';
  // v9：金额统一改分（int）、quotes 增 customer_id、projects 增 due_date/remind_at、
  //      新增 pending_collections（待收款）/ milestones（里程碑）/ invoices（发票）
  static const int dbVersion = 9;

  // ---- 钱包 / 提现 ----
  // 提现账户保存键（settings）：值为 JSON {"method":0,"name":"","no":""}
  static const String withdrawAccountKey = 'withdraw_account';
  // 提现说明：真实通道接入前，提现为"申请登记 + 人工打款"，接入后自动到账
  static const String withdrawNotice = '提现申请提交后由人工核对打款，到账后状态更新为「已提现」；接入官方收款通道后自动到账。';
  // 充值说明：真实通道接入前，充值为"出示收款码 + 手动确认到账"，接入后自动到账
  static const String rechargeNotice = '充值到账后计入钱包余额，可用于后续开通专业版等消费；当前为手动确认模式，付款后请点击「确认到账」完成入账。';

  // ---- 推广活动规则（本地 MVP 版，手动确认）----
  static const int inviteFreeVipFriends = 2; // 推荐好友数达到该值 → 送 1 个月 VIP
  static const double inviteRewardMonths = 1; // 达成推荐目标赠送的 VIP 月数
  static const double rebateRate = 0.50; // 新人真实付款开通 VIP → 按比例返现
}

// 项目状态
enum ProjectStatus {
  accepted, // 接单
  working, // 制作中
  awaiting, // 待收尾款
  done; // 完结

  String get label {
    switch (this) {
      case ProjectStatus.accepted:
        return '接单';
      case ProjectStatus.working:
        return '制作中';
      case ProjectStatus.awaiting:
        return '待收尾款';
      case ProjectStatus.done:
        return '完结';
    }
  }
}

// 收款类型
enum PayType {
  deposit, // 定金
  balance, // 尾款
  full, // 全额
  custom; // 自定义（名称存 payments.type_label）

  String get label {
    switch (this) {
      case PayType.deposit:
        return '定金';
      case PayType.balance:
        return '尾款';
      case PayType.full:
        return '全额';
      case PayType.custom:
        return '自定义';
    }
  }
}

// 意见反馈类型
enum FeedbackType {
  bug, // Bug 反馈
  suggestion, // 更新建议
  other; // 其他

  String get label {
    switch (this) {
      case FeedbackType.bug:
        return 'Bug 反馈';
      case FeedbackType.suggestion:
        return '更新建议';
      case FeedbackType.other:
        return '其他';
    }
  }
}

/// 待收款状态（v9）
enum PendingStatus {
  pending, // 待收款
  done; // 已结清

  String get label {
    switch (this) {
      case PendingStatus.pending:
        return '待收款';
      case PendingStatus.done:
        return '已结清';
    }
  }
}

/// 发票状态（v9）
enum InvoiceStatus {
  draft, // 待开票
  issued, // 已开票
  voided; // 已作废

  String get label {
    switch (this) {
      case InvoiceStatus.draft:
        return '待开票';
      case InvoiceStatus.issued:
        return '已开票';
      case InvoiceStatus.voided:
        return '已作废';
    }
  }
}

/// 金额工具类（v9 起全库金额以「分」为单位的 int 存储与计算，
/// UI 展示统一经此工具转换为「元 + 两位小数」字符串）。
class Money {
  Money._();

  /// 分 → "元"字符串（两位小数）。如 12345 → "123.45"。
  static String yuan(int fen) => (fen / 100).toStringAsFixed(2);

  /// 分 → "¥123.45" 带货币符号。
  static String rmb(int fen) => '¥${yuan(fen)}';

  /// 元（字符串，两位小数或整数输入）→ 分。解析失败返回 0。
  static int parseYuanToFen(String yuan) {
    final v = double.tryParse(yuan.trim());
    if (v == null || v <= 0) return 0;
    return (v * 100).round();
  }
}
