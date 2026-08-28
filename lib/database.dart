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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createUsers(db);
        }
        if (oldVersion < 3) {
          await _createFeedbacks(db);
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
}
