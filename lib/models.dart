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
  final int paidAt;
  final String note;

  const Payment({
    this.id,
    required this.projectId,
    required this.amount,
    required this.type,
    required this.paidAt,
    this.note = '',
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'amount': amount,
        'type': type.index,
        'paid_at': paidAt,
        'note': note,
      };

  factory Payment.fromMap(Map<String, Object?> m) => Payment(
        id: m['id'] as int?,
        projectId: m['project_id'] as int,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        type: PayType.values[m['type'] as int],
        paidAt: m['paid_at'] as int,
        note: (m['note'] as String?) ?? '',
      );
}

// 报价单行（用于计算展示，不入库）
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
  final int? proExpireAt; // 订阅到期时间戳(ms)，null 表示永久（体验模式）

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
