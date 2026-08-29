import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'constants.dart';
import 'models.dart';

/// 密码哈希：固定盐 + 手机号 + 明文密码，sha256。
/// 本地版无服务器，哈希用于避免明文落盘；接入云端后应替换为服务端哈希方案。
String hashPassword(String phone, String raw) {
  final bytes = utf8.encode('jiedan@2026|$phone|$raw');
  return sha256.convert(bytes).toString();
}

class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();
  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, AppConfig.dbName);
    return openDatabase(
      path,
      version: AppConfig.dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE customers(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            contact TEXT,
            note TEXT,
            created_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE projects(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            customer_id INTEGER,
            title TEXT,
            status INTEGER,
            amount_total REAL,
            created_at INTEGER,
            updated_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE payments(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER,
            amount REAL,
            type INTEGER,
            paid_at INTEGER,
            note TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE settings(
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
        await _createUsers(db);
        await _createFeedbacks(db);
        await _createInvitees(db);
        await _createWithdrawals(db);
        await _createRecharges(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createUsers(db);
        }
        if (oldVersion < 3) {
          await _createFeedbacks(db);
        }
        if (oldVersion < 4) {
          await _createInvitees(db);
        }
        if (oldVersion < 5) {
          await _createWithdrawals(db);
        }
        if (oldVersion < 6) {
          await _createRecharges(db);
        }
      },
    );
  }

  /// v2 新增：本地账号表
  Future<void> _createUsers(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        phone TEXT UNIQUE NOT NULL,
        pass_hash TEXT NOT NULL,
        nickname TEXT,
        is_pro INTEGER DEFAULT 0,
        pro_expire_at INTEGER,
        created_at INTEGER
      )
    ''');
  }

  /// v3 新增：意见反馈表（Bug / 建议 / 其他）
  Future<void> _createFeedbacks(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS feedbacks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type INTEGER,
        content TEXT,
        contact TEXT,
        created_at INTEGER
      )
    ''');
  }

  /// v4 新增：推广活动 - 被邀请人表（本地记账，手动确认）
  Future<void> _createInvitees(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS invitees(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        inviter_user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        phone TEXT,
        invited_at INTEGER,
        paid INTEGER DEFAULT 0,
        pay_amount REAL DEFAULT 0,
        rebate REAL DEFAULT 0,
        paid_at INTEGER
      )
    ''');
  }

  /// v5 新增：钱包提现记录表（申请登记 + 人工/自动打款）
  Future<void> _createWithdrawals(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS withdrawals(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount REAL NOT NULL,
        method INTEGER NOT NULL,
        account_name TEXT,
        account_no TEXT,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
  }

  /// v6 新增：钱包充值记录表（出示收款码 + 手动确认到账 / 自动回调）
  Future<void> _createRecharges(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recharges(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount REAL NOT NULL,
        method INTEGER NOT NULL,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
  }

  // ---------- settings ----------
  Future<String?> getSetting(String key) async {
    final d = await db;
    final rows = await d.query('settings', where: 'key=?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    final d = await db;
    await d.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------- customers ----------
  Future<List<Customer>> getCustomers() async {
    final d = await db;
    final rows = await d.query('customers', orderBy: 'created_at DESC');
    return rows.map(Customer.fromMap).toList();
  }

  Future<int> insertCustomer(Customer c) async {
    final d = await db;
    return d.insert('customers', c.toMap()..remove('id'));
  }

  Future<void> updateCustomer(Customer c) async {
    final d = await db;
    await d.update('customers', c.toMap(), where: 'id=?', whereArgs: [c.id]);
  }

  Future<void> deleteCustomer(int id) async {
    final d = await db;
    await d.delete('customers', where: 'id=?', whereArgs: [id]);
  }

  // ---------- projects ----------
  Future<List<Project>> getProjects() async {
    final d = await db;
    final rows = await d.query('projects', orderBy: 'updated_at DESC');
    return rows.map(Project.fromMap).toList();
  }

  Future<List<Project>> getProjectsByCustomer(int customerId) async {
    final d = await db;
    final rows = await d
        .query('projects', where: 'customer_id=?', whereArgs: [customerId]);
    return rows.map(Project.fromMap).toList();
  }

  Future<int> insertProject(Project pr) async {
    final d = await db;
    return d.insert('projects', pr.toMap()..remove('id'));
  }

  Future<void> updateProject(Project pr) async {
    final d = await db;
    await d.update('projects', pr.toMap(), where: 'id=?', whereArgs: [pr.id]);
  }

  Future<void> deleteProject(int id) async {
    final d = await db;
    await d.delete('payments', where: 'project_id=?', whereArgs: [id]);
    await d.delete('projects', where: 'id=?', whereArgs: [id]);
  }

  // ---------- payments ----------
  Future<List<Payment>> getPayments(int projectId) async {
    final d = await db;
    final rows = await d.query('payments',
        where: 'project_id=?', whereArgs: [projectId], orderBy: 'paid_at ASC');
    return rows.map(Payment.fromMap).toList();
  }

  Future<int> insertPayment(Payment pay) async {
    final d = await db;
    return d.insert('payments', pay.toMap()..remove('id'));
  }

  Future<void> deletePayment(int id) async {
    final d = await db;
    await d.delete('payments', where: 'id=?', whereArgs: [id]);
  }

  // 项目已收总额
  Future<double> projectPaidTotal(int projectId) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE project_id=?',
        [projectId]);
    return ((rows.first['t'] as num?) ?? 0).toDouble();
  }

  // 全部项目的已收总额（列表页一次取齐，避免逐项目查询）
  Future<Map<int, double>> projectPaidTotals() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT project_id, COALESCE(SUM(amount),0) AS t FROM payments GROUP BY project_id');
    return {
      for (final r in rows) r['project_id'] as int: ((r['t'] as num?) ?? 0).toDouble(),
    };
  }

  // 本月收入
  Future<double> monthPaidTotal(int year, int month) async {
    final d = await db;
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
        [start, end]);
    return ((rows.first['t'] as num?) ?? 0).toDouble();
  }

  // 指定月份的全部收款明细（含项目标题），按收款时间倒序
  Future<List<Map<String, Object?>>> monthPayments(int year, int month) async {
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    return paymentsInRange(start, end);
  }

  // 任意时间段内的收入合计（年/月/周/自定义区间共用）
  Future<double> paidTotalInRange(int startMs, int endMs) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
        [startMs, endMs]);
    return ((rows.first['t'] as num?) ?? 0).toDouble();
  }

  // 任意时间段内的全部收款明细（含项目标题），按收款时间倒序
  Future<List<Map<String, Object?>>> paymentsInRange(int startMs, int endMs) async {
    final d = await db;
    return d.rawQuery(
        'SELECT p.*, COALESCE(pr.title, \'已删除项目\') AS project_title '
        'FROM payments p LEFT JOIN projects pr ON pr.id = p.project_id '
        'WHERE p.paid_at>=? AND p.paid_at<? '
        'ORDER BY p.paid_at DESC',
        [startMs, endMs]);
  }

  // ---------- users（本地账号）----------
  Future<UserAccount?> getUserByPhone(String phone) async {
    final d = await db;
    final rows = await d.query('users',
        where: 'phone=?', whereArgs: [phone], limit: 1);
    if (rows.isEmpty) return null;
    return UserAccount.fromMap(rows.first);
  }

  Future<int> insertUser(UserAccount u) async {
    final d = await db;
    return d.insert('users', u.toMap()..remove('id'));
  }

  Future<void> updateUser(UserAccount u) async {
    final d = await db;
    await d.update('users', u.toMap(), where: 'id=?', whereArgs: [u.id]);
  }

  /// 当前登录账号（本地会话）
  Future<UserAccount?> getCurrentUser() async {
    final idStr = await getSetting('current_user_id');
    if (idStr == null) return null;
    final d = await db;
    final rows = await d.query('users',
        where: 'id=?', whereArgs: [int.tryParse(idStr)], limit: 1);
    if (rows.isEmpty) return null;
    return UserAccount.fromMap(rows.first);
  }

  Future<void> setCurrentUser(int? id) async {
    if (id == null) {
      await setSetting('current_user_id', '');
    } else {
      await setSetting('current_user_id', '$id');
    }
  }

  // ---------- feedbacks（意见反馈）----------
  Future<int> insertFeedback({
    required int type,
    required String content,
    String contact = '',
  }) async {
    final d = await db;
    return d.insert('feedbacks', {
      'type': type,
      'content': content,
      'contact': contact,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, Object?>>> getFeedbacks() async {
    final d = await db;
    return d.query('feedbacks', orderBy: 'created_at DESC');
  }

  // ---------- invitees（推广活动 - 被邀请人）----------
  Future<List<Invitee>> getInvitees(int inviterUserId) async {
    final d = await db;
    final rows = await d.query('invitees',
        where: 'inviter_user_id=?', whereArgs: [inviterUserId], orderBy: 'invited_at DESC');
    return rows.map(Invitee.fromMap).toList();
  }

  Future<int> insertInvitee(Invitee inv) async {
    final d = await db;
    return d.insert('invitees', inv.toMap()..remove('id'));
  }

  Future<void> updateInvitee(Invitee inv) async {
    final d = await db;
    await d.update('invitees', inv.toMap(), where: 'id=?', whereArgs: [inv.id]);
  }

  Future<void> deleteInvitee(int id) async {
    final d = await db;
    await d.delete('invitees', where: 'id=?', whereArgs: [id]);
  }

  // ---------- 推广活动 - 邀请码（本地生成，存 settings）----------
  /// 读取我的邀请码；不存在则生成并落库。
  Future<String> getOrCreateInviteCode(int userId) async {
    final key = 'invite_code_$userId';
    final exist = await getSetting(key);
    if (exist != null && exist.isNotEmpty) return exist;
    // 生成规则：JD + 4 位（1000+userId），稳定可读；userId 通常很小
    final code = 'JD${1000 + userId}';
    await setSetting(key, code);
    return code;
  }

  /// 我注册时填写的邀请码（来自哪位邀请人），存 settings。
  Future<String?> getMyInviterCode() => getSetting('my_inviter_code');
  Future<void> setMyInviterCode(String code) =>
      setSetting('my_inviter_code', code);

  // ---------- 收款码（微信 / 支付宝二维码图片路径）----------
  Future<String?> getWxQrPath() => getSetting('wx_qr_path');
  Future<void> setWxQrPath(String path) => setSetting('wx_qr_path', path);
  Future<String?> getAliQrPath() => getSetting('ali_qr_path');
  Future<void> setAliQrPath(String path) => setSetting('ali_qr_path', path);

  // ---------- 推广赠送 VIP 状态（避免重复赠送）----------
  Future<bool> inviteBonusGranted(int userId) async {
    final v = await getSetting('invite_bonus_granted_$userId');
    return v == '1';
  }

  Future<void> markInviteBonusGranted(int userId) =>
      setSetting('invite_bonus_granted_$userId', '1');

  // ---------- 钱包 / 提现（v5）----------

  /// 全部已收总额（所有 payments 合计）
  Future<double> allPaidTotal() async {
    final d = await db;
    final rows = await d
        .rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM payments');
    return ((rows.first['t'] as num?) ?? 0).toDouble();
  }

  /// 已提交提现总额（含待处理 / 处理中 / 已提现，均占用可提现额度）
  Future<double> totalWithdrawn() async {
    final d = await db;
    final rows = await d
        .rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM withdrawals');
    return ((rows.first['t'] as num?) ?? 0).toDouble();
  }

  /// 已确认到账的充值总额（仅 status=done）
  Future<double> totalRecharged() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM recharges WHERE status=?',
        [RechargeStatus.done.index]);
    return ((rows.first['t'] as num?) ?? 0).toDouble();
  }

  /// 可提现余额 = 累计收款 + 累计充值到账 - 已提交提现
  Future<double> withdrawableBalance() async {
    final paid = await allPaidTotal();
    final recharged = await totalRecharged();
    final withdrawn = await totalWithdrawn();
    return (paid + recharged - withdrawn).clamp(0, double.infinity);
  }

  Future<int> insertRecharge(Recharge r) async {
    final d = await db;
    return d.insert('recharges', r.toMap()..remove('id'));
  }

  Future<List<Recharge>> getRecharges() async {
    final d = await db;
    final rows = await d.query('recharges', orderBy: 'created_at DESC');
    return rows.map(Recharge.fromMap).toList();
  }

  Future<void> updateRecharge(Recharge r) async {
    final d = await db;
    await d.update('recharges', r.toMap(), where: 'id=?', whereArgs: [r.id]);
  }

  Future<int> insertWithdrawal(Withdrawal w) async {
    final d = await db;
    return d.insert('withdrawals', w.toMap()..remove('id'));
  }

  Future<List<Withdrawal>> getWithdrawals() async {
    final d = await db;
    final rows =
        await d.query('withdrawals', orderBy: 'created_at DESC');
    return rows.map(Withdrawal.fromMap).toList();
  }

  Future<void> updateWithdrawal(Withdrawal w) async {
    final d = await db;
    await d.update('withdrawals', w.toMap(), where: 'id=?', whereArgs: [w.id]);
  }

  /// 读取已保存的提现账户
  Future<WithdrawAccount> getWithdrawAccount() async {
    final raw = await getSetting(AppConfig.withdrawAccountKey);
    return WithdrawAccount.fromJson(raw);
  }

  Future<void> setWithdrawAccount(WithdrawAccount acc) =>
      setSetting(AppConfig.withdrawAccountKey, acc.toJson());
}
