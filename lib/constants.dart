// ============================================================
// 接单管家 - 全局约束参数（硬编码基线）
// 修改产品策略时，只需改动本文件，勿散落各处。
// ============================================================
class AppConfig {
  // ---- 应用基础 ----
  static const String appName = '接单管家';
  static const String version = '1.28.0+37';

  // ---- 云端后端 ----
  // 账号 / 订阅 / 订单 / 推广数据均走云端；业务数据（客户/项目/收款）存储方式
  // 由用户选择（仅本地 / 仅服务器 / 本地+服务器），见 StorageMode。
  static const String apiBaseUrl = 'http://121.41.97.109:8090';
  // ---- HTTPS 证书固定（防破解 P1）----
  // 当前默认仍走 http://121.41.97.109:8090 保持可连；待正式 HTTPS 证书签发后：
  //   1) apiBaseUrl 切为 https://域名；
  //   2) 用 openssl x509 -in server.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -hex
  //      生成服务器证书公钥 SHA-256 指纹填入下方 pinnedCertSha256；
  // 届时客户端仅信任该指纹证书，防止重打包应用把请求劫持到伪造服务器。
  static const String pinnedCertSha256 = '';

  // ---- 防重打包自签名校验（防破解 P3）----
  // 正式 release 签名证书 SHA-256 指纹（keytool -list -v 输出，冒号分隔大写）。
  // 启动时（仅 release 模式）读取 APK 实际签名证书指纹，与本值不一致即判定
  // 包被二次签名/重打包（破解者无法拿到正式 keystore），直接拒绝进入应用。
  // 更换正式签名证书后必须同步更新本常量，否则正式包会被误判为被篡改。
  static const String expectedSigningCertSha256 =
      'F1:79:87:FC:BD:9A:FE:E6:A9:76:79:E7:BE:C2:0E:7C:F8:A3:6E:95:C0:C5:82:50:4E:8E:65:22:89:BA:E8:38';

  // ---- 免费版额度（达到上限后触发付费引导）----
  static const int freeCustomerLimit = 1; // 免费版客户上限
  static const int freeProjectLimit = 3; // 免费版活跃项目上限

  // ---- 订阅定价（第15批 v1.29.0 过渡期：纯 App 端本地闭环，与 README 权益一致）----
  // 首月特惠 1 元，仅限首次开通、每人一次；之后按标准价。
  // 过渡期暂未接入真实支付网关：采用「出示收款码 + 手动确认到账」人工闭环，
  // 手动到账后由云端 isPro 下发；同时支持内置兑换码本地开通（见 app_state.redeemVipCode）。
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
  // v10：invoices（发票）表废弃，替换为 contracts（合同/协议）表
  // v11：数据存储方式改造 —— 核心表新增 updated_at 列 + sync_tombstones 墓碑表
  // v12：反馈回复闭环 —— feedbacks 表新增 server_id / reply / replied_at / synced
  // v13：客户档案补全（行业/来源/所在地/最近联系时间）+ 报价状态流转 + 报价模板
  // v14：迁移机制完善（事务+日志+降级保护），并为高频查询建索引（CREATE INDEX IF NOT EXISTS，纯增量不触碰数据）
  // v15：报价/收款等业务增强（历史遗留，见 database._migrateToV15）
  // v16：第17批 收款对账 —— payments 补 reconciled/quote_id 两列
  // v17：第15批 订阅裂变 —— 新增 subscription_orders 订阅订单表（本地闭环/兑换码/邀请送月）
  static const int dbVersion = 17;

  // ---- 数据存储方式（v1.14.0）----
  // 存储方式的持久化键（settings 表）
  static const String storageModeKey = 'storage_mode';
  // 同步水位键（settings 表）：记录上次成功拉取增量后服务器时间戳
  static const String syncLwmKey = 'sync_lwm';
  // 同步冲突处理策略键（settings 表，v1.20.0）：
  //   auto_newest 自动保留时间较新一方；ask_me 有冲突时先由用户选择。
  static const String syncConflictPolicyKey = 'sync_conflict_policy';
  // 用户选择「保留本地」的忽略集键（settings 表）：JSON Snapshot
  // {"<表名>:<云端id>": <当时服务器时间戳>}；命中时该轮冲突不再重复提示。
  static const String syncKeepLocalKey = 'sync_keep_local';

  // ---- 钱包 / 提现 ----
  // 提现账户保存键（settings）：值为 JSON {"method":0,"name":"","no":""}
  static const String withdrawAccountKey = 'withdraw_account';
  // 提现说明：真实通道接入前，提现为"申请登记 + 人工打款"，接入后自动到账
  static const String withdrawNotice = '提现申请提交后由人工核对打款，到账后状态更新为「已提现」；接入官方收款通道后自动到账。';
  // 充值说明：真实通道接入前，充值为"出示收款码 + 手动确认到账"，接入后自动到账
  static const String rechargeNotice = '充值到账后计入钱包余额，可用于后续开通专业版等消费；当前为手动确认模式，付款后请点击「确认到账」完成入账。';

  // ---- 推广活动规则（第15批 v1.29.0 过渡期：本地自动核验版，与 README 权益一致）----
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

/// 合同/协议状态（v10 替代发票）
enum ContractStatus {
  draft, // 草稿
  signed, // 已签
  done; // 完成

  String get label {
    switch (this) {
      case ContractStatus.draft:
        return '草稿';
      case ContractStatus.signed:
        return '已签';
      case ContractStatus.done:
        return '完成';
    }
  }
}

/// 报价状态（v1.21.0 报价状态流转）。
enum QuoteStatus {
  draft, // 草稿
  sent, // 已发送
  confirmed, // 客户确认
  deal, // 已成交
  voided; // 已作废

  String get label {
    switch (this) {
      case QuoteStatus.draft:
        return '草稿';
      case QuoteStatus.sent:
        return '已发送';
      case QuoteStatus.confirmed:
        return '客户确认';
      case QuoteStatus.deal:
        return '已成交';
      case QuoteStatus.voided:
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

/// 数据存储方式（v1.14.0，三选一，均不收费）。
enum StorageMode {
  /// 仅本地：业务数据只存手机 SQLite，完全不访问云端业务接口（隐私承诺）。
  local,

  /// 仅服务器：以云端为权威存储，本地 SQLite 作为缓存，启动/登录时从云端拉取。
  server,

  /// 本地 + 服务器：双写。本地变更后异步推云端，登录/启动时云端合并回本地。
  both;

  String get label {
    switch (this) {
      case StorageMode.local:
        return '仅本地';
      case StorageMode.server:
        return '仅服务器';
      case StorageMode.both:
        return '本地 + 服务器';
    }
  }

  /// 摘要（设置页/切换确认中展示）
  String get summary {
    switch (this) {
      case StorageMode.local:
        return '数据只保存在本机，不联网、不上传，最私密';
      case StorageMode.server:
        return '数据以云端为准，登录任意设备均可读取';
      case StorageMode.both:
        return '本地与云端双向同步，一处修改处处一致';
    }
  }

  /// 详细说明（选择页展示）
  String get detail {
    switch (this) {
      case StorageMode.local:
        return '客户 / 项目 / 收款 / 报价等全部业务数据仅保存于手机本地（SQLite）。'
            '应用完全不访问云端业务接口，数据不会离开本机；卸载前请先在「数据管理」中导出备份。';
      case StorageMode.server:
        return '业务数据上传服务器，按账号隔离保存；本地仅保留一份缓存。'
            '登录任意设备或重新安装后，数据从云端恢复。断开网络时仅能读取最近一次同步的缓存。';
      case StorageMode.both:
        return '每次修改同时写入本地并在后台同步到云端；登录 / 启动时自动从云端拉取合并回本地。'
            '冲突时以服务器最新数据为准。适合多设备交替使用，既有本地备份又防丢失。';
    }
  }

  /// 是否包含服务器存储（涉及云端业务接口）
  bool get involvesServer =>
      this == StorageMode.server || this == StorageMode.both;
}
