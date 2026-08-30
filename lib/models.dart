import 'dart:convert';

import 'constants.dart';

class Customer {
  final int? id;
  final String name;
  final String contact;
  final String note;
  final int createdAt;

  const Customer({
    this.id,
    required this.name,
    this.contact = '',
    this.note = '',
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'contact': contact,
        'note': note,
        'created_at': createdAt,
      };

  factory Customer.fromMap(Map<String, Object?> m) => Customer(
        id: m['id'] as int?,
        name: m['name'] as String,
        contact: (m['contact'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
      );

  Customer copyWith({String? name, String? contact, String? note}) =>
      Customer(
        id: id,
        name: name ?? this.name,
        contact: contact ?? this.contact,
        note: note ?? this.note,
        createdAt: createdAt,
      );
}

class Project {
  final int? id;
  final int customerId;
  final String title;
  final ProjectStatus status;
  final double amountTotal; // 约定总额
  final int createdAt;
  final int updatedAt;

  const Project({
    this.id,
    required this.customerId,
    required this.title,
    required this.status,
    this.amountTotal = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'customer_id': customerId,
        'title': title,
        'status': status.index,
        'amount_total': amountTotal,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Project.fromMap(Map<String, Object?> m) => Project(
        id: m['id'] as int?,
        customerId: m['customer_id'] as int,
        title: m['title'] as String,
        status: ProjectStatus.values[m['status'] as int],
        amountTotal: ((m['amount_total'] as num?) ?? 0).toDouble(),
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
      );

  Project copyWith({
    String? title,
    ProjectStatus? status,
    double? amountTotal,
    int? updatedAt,
  }) =>
      Project(
        id: id,
        customerId: customerId,
        title: title ?? this.title,
        status: status ?? this.status,
        amountTotal: amountTotal ?? this.amountTotal,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

class Payment {
  final int? id;
  final int projectId;
  final double amount;
  final PayType type;
  final String typeLabel; // 自定义类型名称（type==custom 时有效）
  final int paidAt;
  final String note;

  const Payment({
    this.id,
    required this.projectId,
    required this.amount,
    required this.type,
    this.typeLabel = '',
    required this.paidAt,
    this.note = '',
  });

  /// 展示用收款类型名：自定义类型显示自定义名称，否则显示枚举 label。
  String get displayType =>
      type == PayType.custom ? (typeLabel.trim().isEmpty ? '自定义' : typeLabel.trim()) : type.label;

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'amount': amount,
        'type': type.index,
        'type_label': typeLabel,
        'paid_at': paidAt,
        'note': note,
      };

  factory Payment.fromMap(Map<String, Object?> m) => Payment(
        id: m['id'] as int?,
        projectId: m['project_id'] as int,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        type: PayType.values[m['type'] as int],
        typeLabel: (m['type_label'] as String?) ?? '',
        paidAt: m['paid_at'] as int,
        note: (m['note'] as String?) ?? '',
      );
}

/// 提现方式
enum WithdrawMethod {
  wechat, // 微信
  alipay, // 支付宝
  bank; // 银行卡

  String get label {
    switch (this) {
      case WithdrawMethod.wechat:
        return '微信';
      case WithdrawMethod.alipay:
        return '支付宝';
      case WithdrawMethod.bank:
        return '银行卡';
    }
  }

  String get noHint {
    switch (this) {
      case WithdrawMethod.wechat:
        return '收款微信号';
      case WithdrawMethod.alipay:
        return '收款支付宝账号';
      case WithdrawMethod.bank:
        return '收款银行卡号';
    }
  }
}

/// 提现状态
enum WithdrawStatus {
  pending, // 待处理（已提交申请，等待打款）
  processing, // 处理中（打款进行中）
  done; // 已提现（到账完成）

  String get label {
    switch (this) {
      case WithdrawStatus.pending:
        return '待处理';
      case WithdrawStatus.processing:
        return '处理中';
      case WithdrawStatus.done:
        return '已提现';
    }
  }
}

/// 提现账户（收款人姓名 + 账号），存 settings（JSON）
class WithdrawAccount {
  final WithdrawMethod method;
  final String name; // 收款人姓名
  final String no; // 账号

  const WithdrawAccount({
    this.method = WithdrawMethod.wechat,
    this.name = '',
    this.no = '',
  });

  bool get filled => name.trim().isNotEmpty && no.trim().isNotEmpty;

  String toJson() => jsonEncode({
        'method': method.index,
        'name': name,
        'no': no,
      });

  factory WithdrawAccount.fromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const WithdrawAccount();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final m = (map['method'] as int?) ?? 0;
      return WithdrawAccount(
        method: m >= 0 && m < WithdrawMethod.values.length
            ? WithdrawMethod.values[m]
            : WithdrawMethod.wechat,
        name: (map['name'] as String?) ?? '',
        no: (map['no'] as String?) ?? '',
      );
    } catch (_) {
      return const WithdrawAccount();
    }
  }
}

/// 提现记录（v5 新增）
class Withdrawal {
  final int? id;
  final double amount;
  final WithdrawMethod method;
  final String accountName; // 提现时的收款人姓名（快照）
  final String accountNo; // 提现时的收款账号（快照）
  final WithdrawStatus status;
  final int createdAt;
  final String note;

  const Withdrawal({
    this.id,
    required this.amount,
    required this.method,
    this.accountName = '',
    this.accountNo = '',
    this.status = WithdrawStatus.pending,
    required this.createdAt,
    this.note = '',
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'amount': amount,
        'method': method.index,
        'account_name': accountName,
        'account_no': accountNo,
        'status': status.index,
        'created_at': createdAt,
        'note': note,
      };

  factory Withdrawal.fromMap(Map<String, Object?> m) => Withdrawal(
        id: m['id'] as int?,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        method: WithdrawMethod.values[m['method'] as int],
        accountName: (m['account_name'] as String?) ?? '',
        accountNo: (m['account_no'] as String?) ?? '',
        status: WithdrawStatus.values[(m['status'] as int?) ?? 0],
        createdAt: (m['created_at'] as int?) ?? 0,
        note: (m['note'] as String?) ?? '',
      );

  Withdrawal copyWith({
    int? id,
    double? amount,
    WithdrawMethod? method,
    String? accountName,
    String? accountNo,
    WithdrawStatus? status,
    int? createdAt,
    String? note,
  }) =>
      Withdrawal(
        id: id ?? this.id,
        amount: amount ?? this.amount,
        method: method ?? this.method,
        accountName: accountName ?? this.accountName,
        accountNo: accountNo ?? this.accountNo,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        note: note ?? this.note,
      );
}

/// 充值方式（v6 新增）
enum RechargeMethod {
  wechat, // 微信
  alipay; // 支付宝

  String get label {
    switch (this) {
      case RechargeMethod.wechat:
        return '微信';
      case RechargeMethod.alipay:
        return '支付宝';
    }
  }
}

/// 充值状态（v6 新增）
enum RechargeStatus {
  pending, // 待确认到账（已出示收款码，等待用户确认）
  done; // 已到账（余额已入账）

  String get label {
    switch (this) {
      case RechargeStatus.pending:
        return '待确认';
      case RechargeStatus.done:
        return '已到账';
    }
  }
}

/// 充值记录（v6 新增）。
/// MVP：出示收款码 + 手动确认到账；真实通道接入后由支付回调自动标记 done。
class Recharge {
  final int? id;
  final double amount; // 充值金额（元）
  final RechargeMethod method; // 充值方式
  final RechargeStatus status;
  final int createdAt;
  final String note;

  const Recharge({
    this.id,
    required this.amount,
    this.method = RechargeMethod.wechat,
    this.status = RechargeStatus.pending,
    required this.createdAt,
    this.note = '',
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'amount': amount,
        'method': method.index,
        'status': status.index,
        'created_at': createdAt,
        'note': note,
      };

  factory Recharge.fromMap(Map<String, Object?> m) => Recharge(
        id: m['id'] as int?,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        method: RechargeMethod.values[(m['method'] as int?) ?? 0],
        status: RechargeStatus.values[(m['status'] as int?) ?? 0],
        createdAt: (m['created_at'] as int?) ?? 0,
        note: (m['note'] as String?) ?? '',
      );

  Recharge copyWith({
    int? id,
    double? amount,
    RechargeMethod? method,
    RechargeStatus? status,
    int? createdAt,
    String? note,
  }) =>
      Recharge(
        id: id ?? this.id,
        amount: amount ?? this.amount,
        method: method ?? this.method,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        note: note ?? this.note,
      );
}

// 报价单行（可序列化入库：quotes.lines_json）
class QuoteLine {
  final String itemName;
  final double hours;
  final double hourRate;
  final double materialFee;

  const QuoteLine({
    required this.itemName,
    this.hours = 0,
    this.hourRate = 0,
    this.materialFee = 0,
  });

  double get laborCost => hours * hourRate;
  double get subtotal => laborCost + materialFee;

  Map<String, Object?> toMap() => {
        'itemName': itemName,
        'hours': hours,
        'hourRate': hourRate,
        'materialFee': materialFee,
      };

  factory QuoteLine.fromMap(Map<String, Object?> m) => QuoteLine(
        itemName: (m['itemName'] as String?) ?? '',
        hours: ((m['hours'] as num?) ?? 0).toDouble(),
        hourRate: ((m['hourRate'] as num?) ?? 0).toDouble(),
        materialFee: ((m['materialFee'] as num?) ?? 0).toDouble(),
      );
}

/// 报价单（v7 新增，落库历史；v8 扩展简单/详细两种类型）。
/// 保存后可查看历史、重新打开编辑、复制文本；可关联到项目。
/// - type='simple'：简单报价（一口价含税，无明细/税率，有备注）
/// - type='full'：详细报价（明细 + 税率自动计算）
class Quote {
  final int? id;
  final int? projectId; // 可空：不关联项目
  final String title; // 报价单标题（客户/项目名）
  final double taxRate; // 税率（%）
  final List<QuoteLine> lines;
  final double total; // 报价总额（含税）
  final int createdAt;
  final String type; // 'simple' 简单报价 / 'full' 详细报价
  final String note; // 备注（简单报价常用，详细报价可选）
  final bool taxInclude; // 总额是否含税（简单报价恒 true）

  const Quote({
    this.id,
    this.projectId,
    required this.title,
    this.taxRate = 0,
    this.lines = const [],
    this.total = 0,
    required this.createdAt,
    this.type = 'full',
    this.note = '',
    this.taxInclude = true,
  });

  bool get isSimple => type == 'simple';

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'title': title,
        'tax_rate': taxRate,
        'lines_json': jsonEncode(lines.map((e) => e.toMap()).toList()),
        'total': total,
        'created_at': createdAt,
        'quote_type': type,
        'note': note,
        'tax_include': taxInclude ? 1 : 0,
      };

  factory Quote.fromMap(Map<String, Object?> m) {
    final linesRaw = (m['lines_json'] as String?) ?? '[]';
    List<QuoteLine> lines = [];
    try {
      final list = jsonDecode(linesRaw) as List;
      lines = list
          .map((e) => QuoteLine.fromMap((e as Map).cast<String, Object?>()))
          .toList();
    } catch (_) {/* 解析失败按空行处理 */}
    return Quote(
      id: m['id'] as int?,
      projectId: m['project_id'] as int?,
      title: (m['title'] as String?) ?? '',
      taxRate: ((m['tax_rate'] as num?) ?? 0).toDouble(),
      lines: lines,
      total: ((m['total'] as num?) ?? 0).toDouble(),
      createdAt: (m['created_at'] as int?) ?? 0,
      type: (m['quote_type'] as String?) ?? 'full',
      note: (m['note'] as String?) ?? '',
      taxInclude:
          (m['tax_include'] as int?) == null ? true : (m['tax_include'] as int) == 1,
    );
  }
}

/// 本地账号：手机号 + 密码哈希 + 订阅状态。
/// MVP 阶段无云端，账号与订阅均存于本地 SQLite；
/// 后续接入服务器时仅需替换数据源，模型结构可保持不变。
class UserAccount {
  final int? id;
  final String phone;
  final String passHash; // sha256(固定盐 + phone + password)
  final String nickname;
  final int createdAt;
  final bool isPro; // 是否解锁专业版
  final int? proExpireAt; // 订阅到期时间戳(ms)，null 表示永久（一次买断）

  const UserAccount({
    this.id,
    required this.phone,
    required this.passHash,
    this.nickname = '',
    required this.createdAt,
    this.isPro = false,
    this.proExpireAt,
  });

  /// 订阅是否仍在有效期内
  bool get proActive =>
      isPro && (proExpireAt == null || proExpireAt! > DateTime.now().millisecondsSinceEpoch);

  String get maskedPhone {
    if (phone.length < 7) return phone;
    return '${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}';
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'phone': phone,
        'pass_hash': passHash,
        'nickname': nickname,
        'is_pro': isPro ? 1 : 0,
        'pro_expire_at': proExpireAt,
        'created_at': createdAt,
      };

  factory UserAccount.fromMap(Map<String, Object?> m) => UserAccount(
        id: m['id'] as int?,
        phone: m['phone'] as String,
        passHash: m['pass_hash'] as String,
        nickname: (m['nickname'] as String?) ?? '',
        createdAt: (m['created_at'] as int?) ?? 0,
        isPro: (m['is_pro'] as int?) == 1,
        proExpireAt: m['pro_expire_at'] as int?,
      );

  UserAccount copyWith({
    String? nickname,
    bool? isPro,
    int? proExpireAt,
  }) =>
      UserAccount(
        id: id,
        phone: phone,
        passHash: passHash,
        nickname: nickname ?? this.nickname,
        createdAt: createdAt,
        isPro: isPro ?? this.isPro,
        proExpireAt: proExpireAt ?? this.proExpireAt,
      );
}

/// 被邀请人（推广活动，本地 MVP 版）。
/// 邀请人端手动登记：推荐了谁、谁已真实付款开通 VIP（触发 50% 返现）。
class Invitee {
  final int? id;
  final int inviterUserId; // 邀请人（本机账号）
  final String name; // 被邀请人昵称/称呼
  final String phone; // 被邀请人手机号（选填）
  final int invitedAt;
  final bool paid; // 是否真实付款开通 VIP
  final double payAmount; // 真实付款金额（未付为 0）
  final double rebate; // 对应返现金额 = payAmount * rebateRate
  final int? paidAt;

  const Invitee({
    this.id,
    required this.inviterUserId,
    required this.name,
    this.phone = '',
    required this.invitedAt,
    this.paid = false,
    this.payAmount = 0,
    this.rebate = 0,
    this.paidAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'inviter_user_id': inviterUserId,
        'name': name,
        'phone': phone,
        'invited_at': invitedAt,
        'paid': paid ? 1 : 0,
        'pay_amount': payAmount,
        'rebate': rebate,
        'paid_at': paidAt,
      };

  factory Invitee.fromMap(Map<String, Object?> m) => Invitee(
        id: m['id'] as int?,
        inviterUserId: m['inviter_user_id'] as int,
        name: m['name'] as String,
        phone: (m['phone'] as String?) ?? '',
        invitedAt: (m['invited_at'] as int?) ?? 0,
        paid: (m['paid'] as int?) == 1,
        payAmount: ((m['pay_amount'] as num?) ?? 0).toDouble(),
        rebate: ((m['rebate'] as num?) ?? 0).toDouble(),
        paidAt: m['paid_at'] as int?,
      );

  Invitee copyWith({
    int? id,
    int? inviterUserId,
    String? name,
    String? phone,
    int? invitedAt,
    bool? paid,
    double? payAmount,
    double? rebate,
    int? paidAt,
  }) =>
      Invitee(
        id: id ?? this.id,
        inviterUserId: inviterUserId ?? this.inviterUserId,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        invitedAt: invitedAt ?? this.invitedAt,
        paid: paid ?? this.paid,
        payAmount: payAmount ?? this.payAmount,
        rebate: rebate ?? this.rebate,
        paidAt: paidAt ?? this.paidAt,
      );
}
