// ============================================================
// 接单管家 - 全局约束参数（硬编码基线）
// 修改产品策略时，只需改动本文件，勿散落各处。
// ============================================================
class AppConfig {
  // ---- 应用基础 ----
  static const String appName = '接单管家';
  static const String version = '1.3.1';

  // ---- 免费版额度（达到上限后触发付费引导）----
  static const int freeCustomerLimit = 1; // 免费版客户上限
  static const int freeProjectLimit = 3; // 免费版活跃项目上限

  // ---- 订阅定价（仅展示用，MVP 阶段支付网关未接入）----
  static const double monthlyPrice = 12; // 月订阅价（元）
  static const double yearlyPrice = 88; // 年订阅价（元）

  // ---- 报价默认参数 ----
  static const double defaultHourRate = 150; // 默认工时单价（元/小时）
  static const double defaultTaxRate = 0.06; // 默认综合税率

  // ---- 数据库 ----
  static const String dbName = 'jiedan_guanjia.db';
  static const int dbVersion = 3;
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
  full; // 全额

  String get label {
    switch (this) {
      case PayType.deposit:
        return '定金';
      case PayType.balance:
        return '尾款';
      case PayType.full:
        return '全额';
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
