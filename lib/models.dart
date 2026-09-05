import 'dart:convert';

import 'constants.dart';

// 实体模型层：与数据库表 / 云端 JSON 一一对应。
// 金额字段统一为「分」整数（INTEGER），禁止使用 double（见 database.dart 金额口径）。
// 序列化遵循：toMap/fromMap 走 sqflite 行映射；WithdrawAccount 走 toJson/fromJson（存 settings）。
class Customer {
  final int? id;
  final String name;
  final String contact;
  final String note;
  final String industry; // 行业（v1.21.0 档案补全）
  final String source; // 客户来源（v1.21.0 档案补全）
  final String location; // 所在地（v1.21.0 档案补全）
  final int lastContactAt; // 最近联系时间（ms，v1.21.0）
  final int createdAt;
  final int updatedAt; // 最后修改时间（ms），同步用

  const Customer({
    this.id,
    required this.name,
    this.contact = '',
    this.note = '',
    this.industry = '',
    this.source = '',
    this.location = '',
    this.lastContactAt = 0,
    required this.createdAt,
    this.updatedAt = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'contact': contact,
        'note': note,
        'industry': industry,
        'source': source,
        'location': location,
        'last_contact_at': lastContactAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  // 解析顺序与 toMap / 表列顺序一致；空值统一取默认，避免旧数据缺列崩溃。
  factory Customer.fromMap(Map<String, Object?> m) {
    final fields = {
      'name': (m['name'] as String?) ?? '',
      'contact': (m['contact'] as String?) ?? '',
      'note': (m['note'] as String?) ?? '',
      'industry': (m['industry'] as String?) ?? '',
      'source': (m['source'] as String?) ?? '',
      'location': (m['location'] as String?) ?? '',
    };
    return Customer(
      id: m['id'] as int?,
      name: fields['name']!,
      contact: fields['contact']!,
      note: fields['note']!,
      industry: fields['industry']!,
      source: fields['source']!,
      location: fields['location']!,
      lastContactAt: (m['last_contact_at'] as num?)?.toInt() ?? 0,
      createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
    );
  }

  // 业务合法性：客户名不能为空或纯空白。
  bool isValidCustomer() => name.trim().isNotEmpty;

  Customer copyWith({
    String? name,
    String? contact,
    String? note,
    String? industry,
    String? source,
    String? location,
    int? lastContactAt,
  }) =>
      Customer(
        id: id,
        name: name ?? this.name,
        contact: contact ?? this.contact,
        note: note ?? this.note,
        industry: industry ?? this.industry,
        source: source ?? this.source,
        location: location ?? this.location,
        lastContactAt: lastContactAt ?? this.lastContactAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

class Project {
  final int? id;
  final int customerId;
  final String title;
  final ProjectStatus status;
  final int amountTotal; // 约定总额（分）
  final int createdAt;
  final int updatedAt; // 最后修改时间（ms），同步用
  final int dueDate; // 待收提醒日（ms），0 未设置
  final int remindAt; // 提醒时间点（ms），0 未设置
  final int progress; // 项目进度（%，0-100），v1.24.0
  final int deliverDate; // 交付时间（ms），0 未设置，v1.24.0

  const Project({
    this.id,
    required this.customerId,
    required this.title,
    required this.status,
    this.amountTotal = 0,
    required this.createdAt,
    required this.updatedAt,
    this.dueDate = 0,
    this.remindAt = 0,
    this.progress = 0,
    this.deliverDate = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'customer_id': customerId,
        'title': title,
        'status': status.index,
        'amount_total': amountTotal,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'due_date': dueDate,
        'remind_at': remindAt,
        'progress': progress,
        'deliver_date': deliverDate,
      };

  // status 号越界时兜底到首个枚举，避免历史脏数据触发 RangeError。
  factory Project.fromMap(Map<String, Object?> m) {
    final rawStatus = (m['status'] as int?) ?? 0;
    final statusIndex = rawStatus.clamp(0, ProjectStatus.values.length - 1);
    return Project(
      id: m['id'] as int?,
      customerId: (m['customer_id'] as num?)?.toInt() ?? 0,
      title: (m['title'] as String?) ?? '',
      status: ProjectStatus.values[statusIndex],
      amountTotal: (m['amount_total'] as num?)?.toInt() ?? 0,
      createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      dueDate: (m['due_date'] as num?)?.toInt() ?? 0,
      remindAt: (m['remind_at'] as num?)?.toInt() ?? 0,
      progress: ((m['progress'] as num?)?.toInt() ?? 0).clamp(0, 100),
      deliverDate: (m['deliver_date'] as num?)?.toInt() ?? 0,
    );
  }

  // 业务合法性：项目名不能为空；必须已关联客户（customerId > 0）。
  bool isValidProject() =>
      title.trim().isNotEmpty && customerId > 0;

  Project copyWith({
    int? customerId,
    String? title,
    ProjectStatus? status,
    int? amountTotal,
    int? updatedAt,
    int? dueDate,
    int? remindAt,
    int? progress,
    int? deliverDate,
  }) =>
      Project(
        id: id,
        customerId: customerId ?? this.customerId,
        title: title ?? this.title,
        status: status ?? this.status,
        amountTotal: amountTotal ?? this.amountTotal,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        dueDate: dueDate ?? this.dueDate,
        remindAt: remindAt ?? this.remindAt,
        progress: (progress ?? this.progress).clamp(0, 100),
        deliverDate: deliverDate ?? this.deliverDate,
      );
}

class Payment {
  final int? id;
  final int projectId;
  final int amount; // 金额（分）
  final PayType type;
  final String typeLabel; // 自定义类型名称（type==custom 时有效）
  final int paidAt;
  final String note;
  final int updatedAt; // 最后修改时间（ms），同步用
  final bool reconciled; // 是否已对账（v1.28.0 / db v16，0 未对账 1 已对账）
  final int? quoteId; // 关联报价单 id（v1.28.0 / db v16，可空）

  const Payment({
    this.id,
    required this.projectId,
    required this.amount,
    required this.type,
    this.typeLabel = '',
    required this.paidAt,
    this.note = '',
    this.updatedAt = 0,
    this.reconciled = false,
    this.quoteId,
  });

  // 展示用收款类型名：自定义类型显示自定义名称，否则显示枚举 label。
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
        'updated_at': updatedAt,
        'reconciled': reconciled ? 1 : 0,
        'quote_id': quoteId,
      };

  factory Payment.fromMap(Map<String, Object?> m) => Payment(
        id: m['id'] as int?,
        projectId: (m['project_id'] as num?)?.toInt() ?? 0,
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        type: PayType.values[
            ((m['type'] as int?) ?? 0).clamp(0, PayType.values.length - 1)],
        typeLabel: (m['type_label'] as String?) ?? '',
        paidAt: (m['paid_at'] as num?)?.toInt() ?? 0,
        note: (m['note'] as String?) ?? '',
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
        reconciled: ((m['reconciled'] as num?)?.toInt() ?? 0) == 1,
        quoteId: m['quote_id'] as int?,
      );
}

// 提现方式
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

// 提现状态
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

// 提现账户（收款人姓名 + 账号），存 settings（JSON）
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

// 提现记录（v5 新增）
class Withdrawal {
  final int? id;
  final int amount; // 金额（分）
  final WithdrawMethod method;
  final String accountName; // 提现时收款人姓名（快照）
  final String accountNo; // 提现时收款账号（快照）
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
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        method: WithdrawMethod.values[
            ((m['method'] as int?) ?? 0).clamp(0, WithdrawMethod.values.length - 1)],
        accountName: (m['account_name'] as String?) ?? '',
        accountNo: (m['account_no'] as String?) ?? '',
        status: WithdrawStatus.values[
            ((m['status'] as int?) ?? 0).clamp(0, WithdrawStatus.values.length - 1)],
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
        note: (m['note'] as String?) ?? '',
      );

  Withdrawal copyWith({
    int? id,
    int? amount,
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

// 充值方式（v6 新增）
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

// 充值状态（v6 新增）
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

// 充值记录（v6 新增）：MVP 出示收款码 + 手动确认；真实通道接入后由支付回调自动标 done。
class Recharge {
  final int? id;
  final int amount; // 充值金额（分）
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
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        method: RechargeMethod.values[
            ((m['method'] as int?) ?? 0).clamp(0, RechargeMethod.values.length - 1)],
        status: RechargeStatus.values[
            ((m['status'] as int?) ?? 0).clamp(0, RechargeStatus.values.length - 1)],
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
        note: (m['note'] as String?) ?? '',
      );

  Recharge copyWith({
    int? id,
    int? amount,
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
  final double hours; // 工时（小时，保留小数）
  final int hourRate; // 单价（分/小时）
  final int materialFee; // 材料费（分）

  const QuoteLine({
    required this.itemName,
    this.hours = 0,
    this.hourRate = 0,
    this.materialFee = 0,
  });

  int get laborCost => (hours * hourRate).round(); // 人工费（分）
  int get subtotal => laborCost + materialFee;

  Map<String, Object?> toMap() => {
        'itemName': itemName,
        'hours': hours,
        'hourRate': hourRate,
        'materialFee': materialFee,
      };

  factory QuoteLine.fromMap(Map<String, Object?> m) => QuoteLine(
        itemName: (m['itemName'] as String?) ?? '',
        hours: ((m['hours'] as num?) ?? 0).toDouble(),
        hourRate: (m['hourRate'] as num?)?.toInt() ?? 0,
        materialFee: (m['materialFee'] as num?)?.toInt() ?? 0,
      );
}

// 报价单（v7 落库历史；v8 扩展 simple/full；v9 关联客户 + 金额改分为整数分；
// v1.21.0 状态流转 + 模板）。
// type='simple'：简单报价（一口价含税，无明细/税率）；type='full'：详细报价（明细+税率）。
class Quote {
  final int? id;
  final int? projectId; // 可空：不关联项目
  final int? customerId; // 关联客户（v9），可空
  final String title; // 报价单标题（客户/项目名）
  final double taxRate; // 税率（%）
  final List<QuoteLine> lines;
  final int total; // 报价总额（分，含税）
  final int createdAt;
  final String type; // 'simple' 简单 / 'full' 详细
  final String note; // 备注（简单报价常用，详细报价可选）
  final bool taxInclude; // 总额是否含税（简单报价恒 true）
  final QuoteStatus status; // 状态流转（v1.21.0）
  final bool isTemplate; // 是否为模板（v1.21.0）
  final int updatedAt; // 最后修改时间（ms），同步用
  final String imagePath; // 报价参考图本地路径（v1.24.0，不上传）

  const Quote({
    this.id,
    this.projectId,
    this.customerId,
    required this.title,
    this.taxRate = 0,
    this.lines = const [],
    this.total = 0,
    required this.createdAt,
    this.type = 'full',
    this.note = '',
    this.taxInclude = true,
    this.status = QuoteStatus.draft,
    this.isTemplate = false,
    this.updatedAt = 0,
    this.imagePath = '', // 报价参考图本地路径（不上传），v1.24.0
  });

  bool get isSimple => type == 'simple';

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'customer_id': customerId,
        'title': title,
        'tax_rate': taxRate,
        'lines_json': jsonEncode(lines.map((e) => e.toMap()).toList()),
        'total': total,
        'created_at': createdAt,
        'quote_type': type,
        'note': note,
        'tax_include': taxInclude ? 1 : 0,
        'status': status.index,
        'is_template': isTemplate ? 1 : 0,
        'updated_at': updatedAt,
        'image_path': imagePath,
      };

  // title 先归一化再判断合法性；lines_json 解析失败按空行处理。
  factory Quote.fromMap(Map<String, Object?> m) {
    final lines = _parseLines(m['lines_json']);
    final title = (m['title'] as String?) ?? '';
    final taxIncludeRaw = m['tax_include'] as int?;
    // status 越界（旧库无列时为 null 取 0 草稿）时 clamp，防止崩溃。
    final statusRaw = (m['status'] as num?)?.toInt() ?? 0;
    return Quote(
      id: m['id'] as int?,
      projectId: m['project_id'] as int?,
      customerId: m['customer_id'] as int?,
      title: title,
      taxRate: ((m['tax_rate'] as num?) ?? 0).toDouble(),
      lines: lines,
      total: (m['total'] as num?)?.toInt() ?? 0,
      createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      type: (m['quote_type'] as String?) ?? 'full',
      note: (m['note'] as String?) ?? '',
      taxInclude: taxIncludeRaw == null ? true : taxIncludeRaw == 1,
      status: QuoteStatus.values[
          statusRaw < 0 || statusRaw >= QuoteStatus.values.length ? 0 : statusRaw],
      isTemplate: ((m['is_template'] as num?)?.toInt() ?? 0) == 1,
      updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      imagePath: (m['image_path'] as String?) ?? '',
    );
  }

  // 业务合法性：报价总额不能为负；标题（客户/项目名）不能为空或纯空白。
  bool isValidQuote() => total >= 0 && title.trim().isNotEmpty;

  /// 复制为一份「新建草稿」：清 id / 重置状态与模板标记 / 时间置空，
  /// 供「从模板新建」或已有报价复制时装载到编辑态。
  Quote asNewDraft() => Quote(
        projectId: projectId,
        customerId: customerId,
        title: title,
        taxRate: taxRate,
        lines: lines,
        total: total,
        createdAt: 0, // 占位，保存时重写
        type: type,
        note: note,
        taxInclude: taxInclude,
        status: QuoteStatus.draft,
        isTemplate: false,
      );
}

// lines_json 反序列化 helper（解析失败返回空行）。
List<QuoteLine> _parseLines(Object? json) {
  final raw = (json as String?) ?? '[]';
  try {
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => QuoteLine.fromMap((e as Map).cast<String, Object?>()))
        .toList();
  } catch (_) {
    return const [];
  }
}

// 待收款记录（v9 新增，报价转待收款 / 项目尾款待收）
class PendingCollection {
  final int? id;
  final int? projectId; // 关联项目（可空）
  final int? quoteId; // 来源报价（可空）
  final int? customerId; // 关联客户（可空）
  final String title; // 待收名称（默认项目/报价名）
  final int amount; // 待收金额（分）
  final int dueDate; // 到期日（ms），0 未设置
  final PendingStatus status;
  final int createdAt;
  final int? settledAt; // 结清时间（ms）
  final int updatedAt; // 最后修改时间（ms），同步用

  const PendingCollection({
    this.id,
    this.projectId,
    this.quoteId,
    this.customerId,
    required this.title,
    required this.amount,
    this.dueDate = 0,
    this.status = PendingStatus.pending,
    required this.createdAt,
    this.settledAt,
    this.updatedAt = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'quote_id': quoteId,
        'customer_id': customerId,
        'title': title,
        'amount': amount,
        'due_date': dueDate,
        'status': status.index,
        'created_at': createdAt,
        'settled_at': settledAt,
        'updated_at': updatedAt,
      };

  factory PendingCollection.fromMap(Map<String, Object?> m) => PendingCollection(
        id: m['id'] as int?,
        projectId: m['project_id'] as int?,
        quoteId: m['quote_id'] as int?,
        customerId: m['customer_id'] as int?,
        title: (m['title'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        dueDate: (m['due_date'] as num?)?.toInt() ?? 0,
        status: PendingStatus.values[
            ((m['status'] as int?) ?? 0).clamp(0, PendingStatus.values.length - 1)],
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
        settledAt: m['settled_at'] as int?,
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      );

  PendingCollection copyWith({
    String? title,
    int? amount,
    int? dueDate,
    PendingStatus? status,
    int? settledAt,
  }) =>
      PendingCollection(
        id: id,
        projectId: projectId,
        quoteId: quoteId,
        customerId: customerId,
        title: title ?? this.title,
        amount: amount ?? this.amount,
        dueDate: dueDate ?? this.dueDate,
        status: status ?? this.status,
        createdAt: createdAt,
        settledAt: settledAt ?? this.settledAt,
        updatedAt: updatedAt,
      );
}

// 项目里程碑 / 阶段（v9 新增）
class Milestone {
  final int? id;
  final int projectId;
  final String name; // 阶段名称
  final int amount; // 阶段金额（分）
  final bool done; // 是否完成
  final int createdAt;
  final int updatedAt; // 最后修改时间（ms），同步用

  const Milestone({
    this.id,
    required this.projectId,
    required this.name,
    this.amount = 0,
    this.done = false,
    required this.createdAt,
    this.updatedAt = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'name': name,
        'amount': amount,
        'done': done ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Milestone.fromMap(Map<String, Object?> m) => Milestone(
        id: m['id'] as int?,
        projectId: (m['project_id'] as num?)?.toInt() ?? 0,
        name: (m['name'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        done: (m['done'] as int?) == 1,
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      );

  Milestone copyWith({String? name, int? amount, bool? done}) => Milestone(
        id: id,
        projectId: projectId,
        name: name ?? this.name,
        amount: amount ?? this.amount,
        done: done ?? this.done,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

// 合同/协议记录（v10 替代发票）
class Contract {
  final int? id;
  final String target; // 签约对象（客户/公司名）
  final int amount; // 合同金额（分）
  final int? projectId; // 关联项目（可空）
  final ContractStatus status;
  final int signedAt; // 签订日期（ms）
  final String contractNo; // 合同编号
  final String note; // 备注
  final int updatedAt; // 最后修改时间（ms），同步用

  const Contract({
    this.id,
    required this.target,
    required this.amount,
    this.projectId,
    this.status = ContractStatus.draft,
    required this.signedAt,
    this.contractNo = '',
    this.note = '',
    this.updatedAt = 0,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'target': target,
        'amount': amount,
        'project_id': projectId,
        'status': status.index,
        'signed_at': signedAt,
        'contract_no': contractNo,
        'note': note,
        'updated_at': updatedAt,
      };

  factory Contract.fromMap(Map<String, Object?> m) => Contract(
        id: m['id'] as int?,
        target: (m['target'] as String?) ?? '',
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        projectId: m['project_id'] as int?,
        status: ContractStatus.values[
            ((m['status'] as int?) ?? 0).clamp(0, ContractStatus.values.length - 1)],
        signedAt: (m['signed_at'] as num?)?.toInt() ?? 0,
        contractNo: (m['contract_no'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        updatedAt: (m['updated_at'] as num?)?.toInt() ?? 0,
      );

  Contract copyWith({
    String? target,
    int? amount,
    int? projectId,
    ContractStatus? status,
    int? signedAt,
    String? contractNo,
    String? note,
  }) =>
      Contract(
        id: id,
        target: target ?? this.target,
        amount: amount ?? this.amount,
        projectId: projectId ?? this.projectId,
        status: status ?? this.status,
        signedAt: signedAt ?? this.signedAt,
        contractNo: contractNo ?? this.contractNo,
        note: note ?? this.note,
        updatedAt: updatedAt,
      );
}

// 本地账号：手机号 + 密码哈希 + 订阅状态。
// MVP 无云端，账号/订阅存本地 SQLite；接服务器后仅换数据源，模型保持不变。
class UserAccount {
  final int? id;
  final String phone;
  final String passHash; // sha256(固定盐 + phone + password)
  final String nickname;
  final int createdAt;
  final bool isPro; // 是否解锁专业版
  final int? proExpireAt; // 订阅到期（ms），null 表示永久（一次买断）

  const UserAccount({
    this.id,
    required this.phone,
    required this.passHash,
    this.nickname = '',
    required this.createdAt,
    this.isPro = false,
    this.proExpireAt,
  });

  // 订阅是否仍在有效期内
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
        phone: (m['phone'] as String?) ?? '',
        passHash: (m['pass_hash'] as String?) ?? '',
        nickname: (m['nickname'] as String?) ?? '',
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
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

// 被邀请人（推广活动，本地 MVP 版）。
// 邀请人端手动登记：推荐了谁、谁已真实付款开通 VIP（触发 50% 返现）。
class Invitee {
  final int? id;
  final int inviterUserId; // 邀请人（本机账号）
  final String name; // 被邀请人昵称/称呼
  final String phone; // 被邀请人手机号（选填）
  final int invitedAt;
  final bool paid; // 是否真实付款开通 VIP
  final int payAmount; // 真实付款金额（分，未付为 0）
  final int rebate; // 对应返现金额（分）= payAmount * rebateRate
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
        inviterUserId: (m['inviter_user_id'] as num?)?.toInt() ?? 0,
        name: (m['name'] as String?) ?? '',
        phone: (m['phone'] as String?) ?? '',
        invitedAt: (m['invited_at'] as num?)?.toInt() ?? 0,
        paid: (m['paid'] as int?) == 1,
        payAmount: (m['pay_amount'] as num?)?.toInt() ?? 0,
        rebate: (m['rebate'] as num?)?.toInt() ?? 0,
        paidAt: m['paid_at'] as int?,
      );

  Invitee copyWith({
    int? id,
    int? inviterUserId,
    String? name,
    String? phone,
    int? invitedAt,
    bool? paid,
    int? payAmount,
    int? rebate,
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
