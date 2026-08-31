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
            amount_total INTEGER DEFAULT 0,
            created_at INTEGER,
            updated_at INTEGER,
            due_date INTEGER DEFAULT 0,
            remind_at INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE payments(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER,
            amount INTEGER DEFAULT 0,
            type INTEGER,
            type_label TEXT,
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
        await _createQuotes(db);
        await _createPendingCollections(db);
        await _createMilestones(db);
        await _createContracts(db);
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
        if (oldVersion < 7) {
          await _migrateToV7(db);
        }
        if (oldVersion < 8) {
          await _migrateToV8(db);
        }
        if (oldVersion < 9) {
          await _migrateToV9(db);
        }
        if (oldVersion < 10) {
          await _migrateToV10(db);
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
        pay_amount INTEGER DEFAULT 0,
        rebate INTEGER DEFAULT 0,
        paid_at INTEGER
      )
    ''');
  }

  /// v5 新增：钱包提现记录表（申请登记 + 人工/自动打款）
  Future<void> _createWithdrawals(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS withdrawals(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount INTEGER NOT NULL DEFAULT 0,
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
        amount INTEGER NOT NULL DEFAULT 0,
        method INTEGER NOT NULL,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
  }

  /// v7 新增：报价单历史表；v8 扩展简单/详细类型三列；v9 增 customer_id 列 + 金额改分。
  Future<void> _createQuotes(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS quotes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        customer_id INTEGER,
        title TEXT,
        tax_rate REAL DEFAULT 0,
        lines_json TEXT,
        total INTEGER DEFAULT 0,
        created_at INTEGER,
        quote_type TEXT DEFAULT 'full',
        note TEXT,
        tax_include INTEGER DEFAULT 1
      )
    ''');
  }

  /// v9 新增：待收款记录表（报价转待收款 / 项目待收尾款）
  Future<void> _createPendingCollections(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_collections(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        quote_id INTEGER,
        customer_id INTEGER,
        title TEXT,
        amount INTEGER DEFAULT 0,
        due_date INTEGER DEFAULT 0,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        settled_at INTEGER
      )
    ''');
  }

  /// v9 新增：项目里程碑 / 阶段表
  Future<void> _createMilestones(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS milestones(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        name TEXT,
        amount INTEGER DEFAULT 0,
        done INTEGER DEFAULT 0,
        created_at INTEGER
      )
    ''');
  }

  /// v9 新增：发票记录表（v10 起被 contracts 替代，仅 v9 迁移阶段使用）
  Future<void> _createInvoices(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS invoices(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target TEXT,
        amount INTEGER DEFAULT 0,
        project_id INTEGER,
        status INTEGER DEFAULT 0,
        issued_at INTEGER,
        invoice_no TEXT,
        note TEXT
      )
    ''');
  }

  /// v10 新增：合同/协议记录表（替代 v9 的 invoices）
  Future<void> _createContracts(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contracts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target TEXT,
        amount INTEGER DEFAULT 0,
        project_id INTEGER,
        status INTEGER DEFAULT 0,
        signed_at INTEGER,
        contract_no TEXT,
        note TEXT
      )
    ''');
  }

  /// v10 迁移：废弃 invoices 表，替换为 contracts 表。
  /// 存量发票数据按状态映射迁移（draft→草稿 / issued→已签 / voided→完成），
  /// 迁移完成后删除旧表。
  Future<void> _migrateToV10(Database db) async {
    await _createContracts(db);
    final rows = await db.query('invoices');
    if (rows.isNotEmpty) {
      final b = db.batch();
      for (final r in rows) {
        final oldStatus = (r['status'] as int?) ?? 0;
        final newStatus = switch (oldStatus) {
          1 => 1, // issued -> signed
          2 => 2, // voided -> done
          _ => 0, // draft -> draft
        };
        b.insert('contracts', {
          'id': r['id'],
          'target': r['target'],
          'amount': r['amount'],
          'project_id': r['project_id'],
          'status': newStatus,
          'signed_at': r['issued_at'],
          'contract_no': r['invoice_no'],
          'note': r['note'],
        });
      }
      await b.commit(noResult: true);
    }
    await db.execute('DROP TABLE IF EXISTS invoices');
  }

  /// v7 迁移：
  /// 1. payments 表新增 type_label 列（自定义收款类型名称，存量行置空）；
  /// 2. 新增 quotes 报价单表。
  Future<void> _migrateToV7(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(payments)');
    final hasTypeLabel = cols.any((c) => c['name'] == 'type_label');
    if (!hasTypeLabel) {
      await db.execute('ALTER TABLE payments ADD COLUMN type_label TEXT');
    }
    await _createQuotes(db);
  }

  /// v8 迁移：quotes 表新增 quote_type / note / tax_include 三列。
  /// 存量报价单统一标记为 'full'（详细报价），tax_include 默认 1，note 置空。
  Future<void> _migrateToV8(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(quotes)');
    if (!cols.any((c) => c['name'] == 'quote_type')) {
      await db
          .execute("ALTER TABLE quotes ADD COLUMN quote_type TEXT DEFAULT 'full'");
    }
    if (!cols.any((c) => c['name'] == 'note')) {
      await db.execute('ALTER TABLE quotes ADD COLUMN note TEXT');
    }
    if (!cols.any((c) => c['name'] == 'tax_include')) {
      await db.execute('ALTER TABLE quotes ADD COLUMN tax_include INTEGER DEFAULT 1');
    }
  }

  /// v9 迁移（金额改分 + 新功能表 + 新列）。
  /// SQLite 不支持 ALTER COLUMN 改类型，采用「新表 + 复制 x100 + 换名」重建金额表。
  /// 涉及表：projects / payments / quotes / withdrawals / recharges / invitees。
  /// 新增表：pending_collections / milestones / invoices。
  /// quotes 增 customer_id，projects 增 due_date / remind_at。
  Future<void> _migrateToV9(Database db) async {
    // 1) projects：amount_total 元→分（x100），新增 due_date / remind_at
    final pCols = await db.rawQuery('PRAGMA table_info(projects)');
    final hasDue = pCols.any((c) => c['name'] == 'due_date');
    final hasRemind = pCols.any((c) => c['name'] == 'remind_at');
    await db.execute('''
      CREATE TABLE projects_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id INTEGER,
        title TEXT,
        status INTEGER,
        amount_total INTEGER DEFAULT 0,
        created_at INTEGER,
        updated_at INTEGER,
        due_date INTEGER DEFAULT 0,
        remind_at INTEGER DEFAULT 0
      )
    ''');
    await db.execute('''
      INSERT INTO projects_new(id, customer_id, title, status, amount_total, created_at, updated_at, due_date, remind_at)
      SELECT id, customer_id, title, status, CAST(ROUND(amount_total*100) AS INTEGER), created_at, updated_at,
        ${hasDue ? 'due_date' : '0'}, ${hasRemind ? 'remind_at' : '0'}
      FROM projects
    ''');
    await db.execute('DROP TABLE projects');
    await db.execute('ALTER TABLE projects_new RENAME TO projects');

    // 2) payments：amount 元→分（x100）
    await db.execute('''
      CREATE TABLE payments_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        amount INTEGER DEFAULT 0,
        type INTEGER,
        type_label TEXT,
        paid_at INTEGER,
        note TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO payments_new(id, project_id, amount, type, type_label, paid_at, note)
      SELECT id, project_id, CAST(ROUND(amount*100) AS INTEGER), type, type_label, paid_at, note
      FROM payments
    ''');
    await db.execute('DROP TABLE payments');
    await db.execute('ALTER TABLE payments_new RENAME TO payments');

    // 3) quotes：total 元→分（x100），新增 customer_id 列
    await db.execute('''
      CREATE TABLE quotes_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        customer_id INTEGER,
        title TEXT,
        tax_rate REAL DEFAULT 0,
        lines_json TEXT,
        total INTEGER DEFAULT 0,
        created_at INTEGER,
        quote_type TEXT DEFAULT 'full',
        note TEXT,
        tax_include INTEGER DEFAULT 1
      )
    ''');
    await db.execute('''
      INSERT INTO quotes_new(id, project_id, customer_id, title, tax_rate, lines_json, total, created_at, quote_type, note, tax_include)
      SELECT id, project_id, NULL, title, tax_rate, lines_json, CAST(ROUND(total*100) AS INTEGER), created_at, quote_type, note, tax_include
      FROM quotes
    ''');
    await db.execute('DROP TABLE quotes');
    await db.execute('ALTER TABLE quotes_new RENAME TO quotes');

    // 4) withdrawals：amount 元→分（x100）
    await db.execute('''
      CREATE TABLE withdrawals_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount INTEGER NOT NULL DEFAULT 0,
        method INTEGER NOT NULL,
        account_name TEXT,
        account_no TEXT,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO withdrawals_new(id, amount, method, account_name, account_no, status, created_at, note)
      SELECT id, CAST(ROUND(amount*100) AS INTEGER), method, account_name, account_no, status, created_at, note
      FROM withdrawals
    ''');
    await db.execute('DROP TABLE withdrawals');
    await db.execute('ALTER TABLE withdrawals_new RENAME TO withdrawals');

    // 5) recharges：amount 元→分（x100）
    await db.execute('''
      CREATE TABLE recharges_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount INTEGER NOT NULL DEFAULT 0,
        method INTEGER NOT NULL,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO recharges_new(id, amount, method, status, created_at, note)
      SELECT id, CAST(ROUND(amount*100) AS INTEGER), method, status, created_at, note
      FROM recharges
    ''');
    await db.execute('DROP TABLE recharges');
    await db.execute('ALTER TABLE recharges_new RENAME TO recharges');

    // 6) invitees：pay_amount / rebate 元→分（x100）
    await db.execute('''
      CREATE TABLE invitees_new(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        inviter_user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        phone TEXT,
        invited_at INTEGER,
        paid INTEGER DEFAULT 0,
        pay_amount INTEGER DEFAULT 0,
        rebate INTEGER DEFAULT 0,
        paid_at INTEGER
      )
    ''');
    await db.execute('''
      INSERT INTO invitees_new(id, inviter_user_id, name, phone, invited_at, paid, pay_amount, rebate, paid_at)
      SELECT id, inviter_user_id, name, phone, invited_at, paid, CAST(ROUND(pay_amount*100) AS INTEGER), CAST(ROUND(rebate*100) AS INTEGER), paid_at
      FROM invitees
    ''');
    await db.execute('DROP TABLE invitees');
    await db.execute('ALTER TABLE invitees_new RENAME TO invitees');

    // 7) 新增表
    await _createPendingCollections(db);
    await _createMilestones(db);
    await _createInvoices(db);
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
    if (idStr == null || idStr.isEmpty) return null;
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
    // 级联删除：先删该客户全部项目（deleteProject 已级联删 payments/里程碑/待收/报价/发票），再删客户
    final projects = await d
        .query('projects', where: 'customer_id=?', whereArgs: [id]);
    for (final pr in projects) {
      await deleteProject(pr['id'] as int);
    }
    await d.delete('pending_collections', where: 'customer_id=?', whereArgs: [id]);
    await d.delete('quotes', where: 'customer_id=?', whereArgs: [id]);
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
    await d.delete('milestones', where: 'project_id=?', whereArgs: [id]);
    await d.delete('pending_collections', where: 'project_id=?', whereArgs: [id]);
    await d.delete('invoices', where: 'project_id=?', whereArgs: [id]);
    await d.delete('contracts', where: 'project_id=?', whereArgs: [id]);
    await d.delete('quotes', where: 'project_id=?', whereArgs: [id]);
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

  // 项目已收总额（分）
  Future<int> projectPaidTotal(int projectId) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE project_id=?',
        [projectId]);
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 全部项目的已收总额（列表页一次取齐，避免逐项目查询），值为分
  Future<Map<int, int>> projectPaidTotals() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT project_id, COALESCE(SUM(amount),0) AS t FROM payments GROUP BY project_id');
    return {
      for (final r in rows)
        r['project_id'] as int: (r['t'] as num?)?.toInt() ?? 0,
    };
  }

  // 本月收入（分）
  Future<int> monthPaidTotal(int year, int month) async {
    final d = await db;
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
        [start, end]);
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 指定月份的全部收款明细（含项目标题），按收款时间倒序
  Future<List<Map<String, Object?>>> monthPayments(int year, int month) async {
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    return paymentsInRange(start, end);
  }

  // 任意时间段内的收入合计（年/月/周/自定义区间共用），值为分
  Future<int> paidTotalInRange(int startMs, int endMs) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
        [startMs, endMs]);
    return (rows.first['t'] as num?)?.toInt() ?? 0;
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

  // 近 12 个月每月收入（分），返回 [(年, 月, 金额)]
  Future<List<Map<String, int>>> monthlyIncomeLast12() async {
    final d = await db;
    final now = DateTime.now();
    final list = <Map<String, int>>[];
    for (int i = 11; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      final start = m.millisecondsSinceEpoch;
      final end = DateTime(now.year, now.month - i + 1, 1).millisecondsSinceEpoch;
      final rows = await d.rawQuery(
          'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
          [start, end]);
      list.add({
        'year': m.year,
        'month': m.month,
        'amount': (rows.first['t'] as num?)?.toInt() ?? 0,
      });
    }
    return list;
  }

  // 客户贡献排行（分）：按项目归属客户汇总已收金额，返回 [(customerName, totalFen)]
  Future<List<Map<String, Object?>>> customerContribution() async {
    final d = await db;
    return d.rawQuery('''
      SELECT COALESCE(c.name, '未关联客户') AS customer_name,
             COALESCE(SUM(p.amount),0) AS total
      FROM payments p
      LEFT JOIN projects pr ON pr.id = p.project_id
      LEFT JOIN customers c ON c.id = pr.customer_id
      GROUP BY COALESCE(c.name, '未关联客户')
      ORDER BY total DESC
    ''');
  }

  // 待收总额（分）：所有 status=pending 的待收款合计
  Future<int> pendingTotal() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM pending_collections WHERE status=?',
        [PendingStatus.pending.index]);
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 收款 / 待收构成：已收总额 与 待收总额（分）
  Future<Map<String, int>> paidVsPendingSummary() async {
    final paid = await allPaidTotal();
    final pending = await pendingTotal();
    return {'paid': paid, 'pending': pending};
  }

  // 对账汇总：每个项目 约定总额/已收/待收（分）
  Future<List<Map<String, Object?>>> reconciliationSummary() async {
    final d = await db;
    return d.rawQuery('''
      SELECT pr.id AS project_id,
             COALESCE(pr.title, '已删除项目') AS project_title,
             COALESCE(c.name, '未关联客户') AS customer_name,
             COALESCE(pr.amount_total,0) AS amount_total,
             COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.project_id = pr.id),0) AS paid_total,
             COALESCE((SELECT SUM(pc.amount) FROM pending_collections pc WHERE pc.project_id = pr.id AND pc.status = 0),0) AS pending_total
      FROM projects pr
      LEFT JOIN customers c ON c.id = pr.customer_id
      ORDER BY pr.updated_at DESC
    ''');
  }

  // 有待收提醒设置的项目（due_date>0 且存在未结清待收）
  Future<List<Map<String, Object?>>> projectsWithPendingReminder() async {
    final d = await db;
    return d.rawQuery('''
      SELECT pr.id AS project_id, pr.title AS project_title, pr.due_date,
             COALESCE((SELECT SUM(pc.amount) FROM pending_collections pc WHERE pc.project_id = pr.id AND pc.status = 0),0) AS pending_total
      FROM projects pr
      WHERE pr.due_date > 0
        AND EXISTS(SELECT 1 FROM pending_collections pc WHERE pc.project_id = pr.id AND pc.status = 0)
    ''');
  }

  // ---------- quotes（报价单历史，v7）----------
  Future<List<Quote>> getQuotes() async {
    final d = await db;
    final rows = await d.query('quotes', orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  Future<List<Quote>> getQuotesByCustomer(int customerId) async {
    final d = await db;
    final rows = await d.query('quotes',
        where: 'customer_id=?', whereArgs: [customerId], orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  Future<List<Quote>> getQuotesByProject(int projectId) async {
    final d = await db;
    final rows = await d.query('quotes',
        where: 'project_id=?', whereArgs: [projectId], orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  Future<int> insertQuote(Quote q) async {
    final d = await db;
    return d.insert('quotes', q.toMap()..remove('id'));
  }

  Future<void> updateQuote(Quote q) async {
    final d = await db;
    await d.update('quotes', q.toMap(), where: 'id=?', whereArgs: [q.id]);
  }

  Future<void> deleteQuote(int id) async {
    final d = await db;
    await d.delete('quotes', where: 'id=?', whereArgs: [id]);
  }

  // ---------- pending_collections（待收款，v9）----------
  Future<List<PendingCollection>> getPendingCollections({bool onlyPending = false}) async {
    final d = await db;
    final rows = onlyPending
        ? await d.query('pending_collections',
            where: 'status=?', whereArgs: [PendingStatus.pending.index], orderBy: 'created_at DESC')
        : await d.query('pending_collections', orderBy: 'created_at DESC');
    return rows.map(PendingCollection.fromMap).toList();
  }

  Future<int> insertPendingCollection(PendingCollection pc) async {
    final d = await db;
    return d.insert('pending_collections', pc.toMap()..remove('id'));
  }

  Future<void> updatePendingCollection(PendingCollection pc) async {
    final d = await db;
    await d.update('pending_collections', pc.toMap(),
        where: 'id=?', whereArgs: [pc.id]);
  }

  Future<void> settlePending(int id) async {
    final d = await db;
    await d.update(
        'pending_collections',
        {
          'status': PendingStatus.done.index,
          'settled_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id=?',
        whereArgs: [id]);
  }

  Future<void> deletePendingCollection(int id) async {
    final d = await db;
    await d.delete('pending_collections', where: 'id=?', whereArgs: [id]);
  }

  // ---------- milestones（项目里程碑，v9）----------
  Future<List<Milestone>> getMilestones(int projectId) async {
    final d = await db;
    final rows = await d.query('milestones',
        where: 'project_id=?', whereArgs: [projectId], orderBy: 'created_at ASC');
    return rows.map(Milestone.fromMap).toList();
  }

  Future<int> insertMilestone(Milestone ms) async {
    final d = await db;
    return d.insert('milestones', ms.toMap()..remove('id'));
  }

  Future<void> updateMilestone(Milestone ms) async {
    final d = await db;
    await d.update('milestones', ms.toMap(), where: 'id=?', whereArgs: [ms.id]);
  }

  Future<void> deleteMilestone(int id) async {
    final d = await db;
    await d.delete('milestones', where: 'id=?', whereArgs: [id]);
  }

  // ---------- contracts（合同/协议，v10）----------
  Future<List<Contract>> getContracts() async {
    final d = await db;
    final rows = await d.query('contracts', orderBy: 'signed_at DESC');
    return rows.map(Contract.fromMap).toList();
  }

  Future<int> insertContract(Contract c) async {
    final d = await db;
    return d.insert('contracts', c.toMap()..remove('id'));
  }

  Future<void> updateContract(Contract c) async {
    final d = await db;
    await d.update('contracts', c.toMap(), where: 'id=?', whereArgs: [c.id]);
  }

  Future<void> deleteContract(int id) async {
    final d = await db;
    await d.delete('contracts', where: 'id=?', whereArgs: [id]);
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

  /// 全部已收总额（所有 payments 合计），分为单位
  Future<int> allPaidTotal() async {
    final d = await db;
    final rows = await d
        .rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM payments');
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  /// 已提交提现总额（含待处理 / 处理中 / 已提现，均占用可提现额度），分为单位
  Future<int> totalWithdrawn() async {
    final d = await db;
    final rows = await d
        .rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM withdrawals');
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  /// 已确认到账的充值总额（仅 status=done），分为单位
  Future<int> totalRecharged() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM recharges WHERE status=?',
        [RechargeStatus.done.index]);
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  /// 可提现余额（分）= 累计收款 + 累计充值到账 - 已提交提现
  Future<int> withdrawableBalance() async {
    final paid = await allPaidTotal();
    final recharged = await totalRecharged();
    final withdrawn = await totalWithdrawn();
    final v = paid + recharged - withdrawn;
    return v < 0 ? 0 : v;
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
