import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'constants.dart';
import 'models.dart';

// ============================================================
// 金额口径（全库统一约束）
// 本系统所有金额字段一律以「分」为单位，用 INTEGER 整数存储、运算，
// 禁止使用 double 浮点类型（防止精度丢失）；仅 UI 展示层按 元+两位小数 格式化。
// 涉及字段（均存分）：projects.amount_total、payments.amount、
// quotes.total、pending_collections.amount、milestones.amount、
// contracts.amount、withdrawals.amount、recharges.amount、
// invitees.pay_amount / rebate。
// ============================================================

// 数据库读写异常体系（业务可识别，按异常原因拆 4 类）：
//  - 数据库文件损坏 / 无法打开
//  - 约束冲突（主键 / 唯一键冲突）
//  - 写入权限不足（只读 / 磁盘满 / 无法写入）
//  - 记录不存在（按 id 更新或删除时影响行数为 0）
// 其余未知异常走 DbException 通用兜底。上层可直接 catch 并展示 message（中文）。
class DbException implements Exception {
  final String message;
  DbException(this.message);
  @override
  String toString() => message;
}

class DbCorruptException extends DbException {
  DbCorruptException() : super('数据库文件损坏或无法打开，请备份数据后重装应用');
}

class DbConstraintException extends DbException {
  DbConstraintException() : super('数据唯一性约束冲突，请检查输入内容后重试');
}

class DbPermissionException extends DbException {
  DbPermissionException() : super('存储空间不足或无写入权限，请清理空间后重试');
}

class DbNotFoundException extends DbException {
  DbNotFoundException() : super('目标记录不存在或已被删除');
}

// 密码哈希（固定盐+手机号+明文，sha256）：本地版防明文落盘；上云后换服务端方案。
String hashPassword(String phone, String raw) {
  final bytes = utf8.encode('jiedan@2026|$phone|$raw');
  return sha256.convert(bytes).toString();
}

class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();
  Database? _db;

  // 业务数据（同步范围表）发生本地写入/删除时回调，由 SyncService 挂接做异步推送。
  static void Function()? onDataChanged;

  void _notify() {
    onDataChanged?.call();
  }

  // 当前写入时间戳，供 updated_at 使用。
  static int now() => DateTime.now().millisecondsSinceEpoch;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  // ============================================================
  // 异常分类：把 sqflite 抛出的 DatabaseException 归入 4 类业务异常。
  // SQLite 原生错误码：11=CORRUPT 26=NOTADB（损坏）；
  // 19=CONSTRAINT（约束冲突）；8=READONLY 13=FULL 14=CANTOPEN（权限/空间）。
  // ============================================================
  DbException _classify(DatabaseException e) {
    final code = e.getResultCode();
    if (code != null) {
      if (code == 11 || code == 26) return DbCorruptException();
      if (code == 19) return DbConstraintException();
      if (code == 8 || code == 13 || code == 14) return DbPermissionException();
    }
    final msg = e.toString();
    if (msg.contains('corrupt') ||
        msg.contains('not a database') ||
        msg.contains('database is malformed')) {
      return DbCorruptException();
    }
    if (msg.contains('constraint') || msg.contains('UNIQUE')) {
      return DbConstraintException();
    }
    if (msg.contains('readonly') ||
        msg.contains('full') ||
        msg.contains('permission') ||
        msg.contains('disk I/O')) {
      return DbPermissionException();
    }
    return DbException('数据库操作失败：$msg');
  }

  // 统一执行入口：捕获 DatabaseException 并分类抛出中文业务异常。
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DatabaseException catch (e) {
      throw _classify(e);
    }
  }

  // ============================================================
  // 公共 CRUD 工具函数：把重复的 查/增/改/删 样板收敛到这里。
  //  - _all / _one：通用查询
  //  - _insert / _insertSync：插入（Sync 版补 updated_at + 触发同步通知）
  //  - _updateById / _updateByWhere / _updateSyncById：更新（0 行按需报记录不存在）
  //  - _deleteById / _deleteByWhere / _deleteSyncById：删除（级联删除用 ByWhere，允许 0 行）
  // 同步范围表（带 updated_at/tombstone/notify）：customers/projects/payments/
  // quotes/pending_collections/milestones/contracts，务必走 Sync 版。
  // ============================================================

  Future<List<Map<String, Object?>>> _all(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    final d = await db;
    return _guard(
      () => d.query(table,
          where: where, whereArgs: whereArgs, orderBy: orderBy, limit: limit),
    );
  }

  Future<Map<String, Object?>?> _one(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = await _all(table, where: where, whereArgs: whereArgs, limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // 普通插入（无 updated_at / 无同步通知），返回自增 id。
  Future<int> _insert(String table, Map<String, Object?> data) async {
    final d = await db;
    return _guard(() => d.insert(table, data));
  }

  // 同步表插入：自动补 updated_at 并触发同步通知。
  Future<int> _insertSync(String table, Map<String, Object?> data) async {
    final id = await _insert(table, {...data, 'updated_at': now()});
    _notify();
    return id;
  }

  // 普通按 id 更新；影响 0 行时按 strict 决定是否抛「记录不存在」。
  Future<void> _updateById(
    String table,
    Map<String, Object?> data,
    int id, {
    bool strict = true,
  }) async {
    final d = await db;
    final n = await _guard(() => d.update(table, data,
        where: 'id=?', whereArgs: [id]));
    if (n == 0 && strict) throw DbNotFoundException();
  }

  // 按条件更新（settle / 回复合并等场景，允许命中 0 行不报错）。
  Future<void> _updateByWhere(
    String table,
    Map<String, Object?> data, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final d = await db;
    await _guard(
        () => d.update(table, data, where: where, whereArgs: whereArgs));
  }

  // 同步表更新：补 updated_at 并触发同步通知。
  Future<void> _updateSyncById(
      String table, Map<String, Object?> data, int id) async {
    await _updateById(table, {...data, 'updated_at': now()}, id);
    _notify();
  }

  // 普通按 id 删除；影响 0 行时按 strict 决定是否抛「记录不存在」。
  Future<void> _deleteById(
    String table,
    int id, {
    bool strict = true,
  }) async {
    final d = await db;
    final n = await _guard(() => d.delete(table,
        where: 'id=?', whereArgs: [id]));
    if (n == 0 && strict) throw DbNotFoundException();
  }

  // 按条件删除（级联清理用，允许命中 0 行不报错）。
  Future<void> _deleteByWhere(
    String table, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final d = await db;
    await _guard(() => d.delete(table, where: where, whereArgs: whereArgs));
  }

  // 同步表删除：删除 + 记墓碑 + 触发同步通知。
  Future<void> _deleteSyncById(String table, int id) async {
    await _deleteById(table, id);
    await addTombstone(table, id);
    _notify();
  }

  // ============================================================
  // 打开 / 建库 / 版本迁移
  // ============================================================
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
            industry TEXT,
            source TEXT,
            location TEXT,
            last_contact_at INTEGER DEFAULT 0,
            created_at INTEGER,
            updated_at INTEGER
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
            remind_at INTEGER DEFAULT 0,
            progress INTEGER DEFAULT 0,
            deliver_date INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE payments(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id INTEGER,
            amount INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
            type INTEGER,
            type_label TEXT,
            paid_at INTEGER,
            note TEXT,
            reconciled INTEGER DEFAULT 0, -- 已/未对账标记（0 未对账 / 1 已对账，默认 0）
            quote_id INTEGER -- 关联报价单 id（可空，未关联时为 NULL）
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
        await _createSubscriptionOrders(db);
      },
      // 逐版本迁移（if(oldVersion<X) 保证老用户数据不丢、每个版本只补差量）：
      // 新增未来版本时，只需在下方追加 if(oldVersion<N+1){ await _migrateToVN+1(db); }，
      // 并在对应迁移函数内用 PRAGMA table_info 探测列后再 ALTER。
      // 迁移统一走 _runMigration：集中管理全部历史版本差量路径 + 事务回滚保护 + 日志留痕。
      onUpgrade: (db, oldVersion, newVersion) async {
        await _runMigration(db, oldVersion, newVersion);
      },
      // 降级保护（v1.23.0）：本地数据库版本高于当前应用可处理版本（例如用户回退安装
      // 旧 APK）时，绝不执行任何 DDL / 数据改动，直接拒绝打开，避免新版数据结构被
      // 旧版代码误操作破坏。用户如需回退旧版，应先在新版「数据管理」导出备份。
      onDowngrade: (db, oldVersion, newVersion) async {
        throw DbException(
          '检测到本地数据版本(v$oldVersion)高于当前应用可处理的版本(v$newVersion)，'
          '为防止数据被破坏已停止打开数据库。请安装不低于原版本的应用（或先还原旧版数据备份）。',
        );
      },
    );
  }

  // 迁移成功/失败日志的 settings 键（保留最近若干条，便于排查版本升级问题）。
  static const String _kDbMigrationLogKey = 'db_migration_log';

  // 迁移统一入口：按 oldVersion 逐级补齐到 newVersion，保证「任意历史版本（v1~v13…）
  // 升级到当前版本」都有对应的差量迁移路径，绝不会因跨多个版本而跳版本。
  // 迁移在 Android SQLiteOpenHelper 为 onUpgrade 包裹的事务内执行：任一步骤失败会
  // 整体回滚，schema 保持升级前版本、业务数据完好，应用下次打开可再次重试；
  // 成功/失败都会写入 settings 留痕（db_migration_log）。
  Future<void> _runMigration(Database db, int oldVersion, int newVersion) async {
    try {
      if (oldVersion < 2) await _createUsers(db);
      if (oldVersion < 3) await _createFeedbacks(db);
      if (oldVersion < 4) await _createInvitees(db);
      if (oldVersion < 5) await _createWithdrawals(db);
      if (oldVersion < 6) await _createRecharges(db);
      if (oldVersion < 7) await _migrateToV7(db);
      if (oldVersion < 8) await _migrateToV8(db);
      if (oldVersion < 9) await _migrateToV9(db);
      if (oldVersion < 10) await _migrateToV10(db);
      if (oldVersion < 11) await _migrateToV11(db);
      if (oldVersion < 12) await _migrateToV12(db);
      if (oldVersion < 13) await _migrateToV13(db);
      if (oldVersion < 14) await _migrateToV14(db);
      if (oldVersion < 15) await _migrateToV15(db);
      if (oldVersion < 16) await _migrateToV16(db);
      if (oldVersion < 17) await _migrateToV17(db);
      await _appendMigrationLog(db, '成功 v$oldVersion -> v$newVersion @ $now()');
    } catch (e, st) {
      // 记录失败日志后抛出统一中文异常；平台事务回滚后数据库保持旧版本与全部数据，
      // 上层（AppState.load）可感知并提示用户重试，不会静默损坏数据。
      try {
        await _appendMigrationLog(db, '失败 v$oldVersion -> v$newVersion @ $now()\n$e\n$st');
      } catch (_) {}
      throw DbException(
        '数据库从 v$oldVersion 升级到 v$newVersion 失败，已自动回滚，数据未受影响。'
        '请重启应用重试；若持续失败，请先在「数据管理」中导出备份后卸载重装。原因：$e',
      );
    }
  }

  Future<void> _appendMigrationLog(Database db, String line) async {
    final rows = await db.query('settings',
        where: 'key=?', whereArgs: [_kDbMigrationLogKey], orderBy: 'rowid DESC', limit: 5);
    final prev = rows.isEmpty ? '' : '${rows.first['value']}\n';
    await db.insert('settings', {'key': _kDbMigrationLogKey, 'value': '$prev$line'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // v2 新增：本地账号表
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

  // v3 新增：意见反馈表（Bug / 建议 / 其他）
  Future<void> _createFeedbacks(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS feedbacks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type INTEGER,
        content TEXT,
        contact TEXT,
        created_at INTEGER,
        server_id INTEGER,
        reply TEXT,
        replied_at INTEGER,
        synced INTEGER DEFAULT 1
      )
    ''');
  }

  // v4 新增：推广活动 - 被邀请人表（本地记账，手动确认）
  Future<void> _createInvitees(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS invitees(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        inviter_user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        phone TEXT,
        invited_at INTEGER,
        paid INTEGER DEFAULT 0,
        pay_amount INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        rebate INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        paid_at INTEGER
      )
    ''');
  }

  // v5 新增：钱包提现记录表（申请登记 + 人工/自动打款）
  Future<void> _createWithdrawals(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS withdrawals(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount INTEGER NOT NULL DEFAULT 0, -- 金额单位：分，禁止 double
        method INTEGER NOT NULL,
        account_name TEXT,
        account_no TEXT,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
  }

  // v6 新增：钱包充值记录表（出示收款码 + 手动确认到账 / 自动回调）
  Future<void> _createRecharges(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recharges(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount INTEGER NOT NULL DEFAULT 0, -- 金额单位：分，禁止 double
        method INTEGER NOT NULL,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        note TEXT
      )
    ''');
  }

  // v7 新增：报价单历史表；v8 扩展 simple/full 类型三列；v9 新增 customer_id 列 + 金额改分；
  // v1.21.0 状态流转（status）+ 模板（is_template）+ 同步 updated_at。
  Future<void> _createQuotes(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS quotes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        customer_id INTEGER,
        title TEXT,
        tax_rate REAL DEFAULT 0,
        lines_json TEXT,
        total INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        created_at INTEGER,
        quote_type TEXT DEFAULT 'full',
        note TEXT,
        tax_include INTEGER DEFAULT 1,
        status INTEGER DEFAULT 0,
        is_template INTEGER DEFAULT 0,
        updated_at INTEGER,
        image_path TEXT
      )
    ''');
  }

  // v9 新增：待收款记录表（报价转待收款 / 项目待收尾款）
  Future<void> _createPendingCollections(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_collections(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        quote_id INTEGER,
        customer_id INTEGER,
        title TEXT,
        amount INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        due_date INTEGER DEFAULT 0,
        status INTEGER DEFAULT 0,
        created_at INTEGER,
        settled_at INTEGER
      )
    ''');
  }

  // v9 新增：项目里程碑 / 阶段表
  Future<void> _createMilestones(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS milestones(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER,
        name TEXT,
        amount INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        done INTEGER DEFAULT 0,
        created_at INTEGER
      )
    ''');
  }

  // v9 新增：发票记录表（v10 起被 contracts 替代，仅 v9 迁移阶段使用）
  Future<void> _createInvoices(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS invoices(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target TEXT,
        amount INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        project_id INTEGER,
        status INTEGER DEFAULT 0,
        issued_at INTEGER,
        invoice_no TEXT,
        note TEXT
      )
    ''');
  }

  // v10 新增：合同/协议记录表（替代 v9 的 invoices）
  Future<void> _createContracts(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contracts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        target TEXT,
        amount INTEGER DEFAULT 0, -- 金额单位：分，禁止 double
        project_id INTEGER,
        status INTEGER DEFAULT 0,
        signed_at INTEGER,
        contract_no TEXT,
        note TEXT
      )
    ''');
  }

  // v10 迁移：invoices 废弃→contracts 替换。状态映射（draft→草稿/issued→已签/voided→完成），
  // 存量行拷入后删旧表。注意迁移期金额为旧「元」，到 v9 已统一为「分」。
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

  // v11 迁移：核心同步表补 updated_at 列 + 新增 sync_tombstones 墓碑表
  // （table + row_id + deleted_at，供增量同步回传删除操作）。
  Future<void> _migrateToV11(Database db) async {
    for (final t in ['customers', 'payments', 'quotes', 'pending_collections', 'milestones', 'contracts']) {
      final cols = await db.rawQuery('PRAGMA table_info($t)');
      if (!cols.any((c) => c['name'] == 'updated_at')) {
        await db.execute('ALTER TABLE $t ADD COLUMN updated_at INTEGER');
      }
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_tombstones(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        row_id INTEGER NOT NULL,
        deleted_at INTEGER
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_tomb_table ON sync_tombstones(table_name)');
  }

  // v12 迁移：feedbacks 补作者回复字段。
  // server_id 服务器反馈 id；reply/replied_at 作者回复；synced 1=已同步 0=本地草稿。
  Future<void> _migrateToV12(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(feedbacks)');
    if (!cols.any((c) => c['name'] == 'server_id')) {
      await db.execute('ALTER TABLE feedbacks ADD COLUMN server_id INTEGER');
    }
    if (!cols.any((c) => c['name'] == 'reply')) {
      await db.execute('ALTER TABLE feedbacks ADD COLUMN reply TEXT');
    }
    if (!cols.any((c) => c['name'] == 'replied_at')) {
      await db.execute('ALTER TABLE feedbacks ADD COLUMN replied_at INTEGER');
    }
    if (!cols.any((c) => c['name'] == 'synced')) {
      await db.execute('ALTER TABLE feedbacks ADD COLUMN synced INTEGER DEFAULT 1');
    }
  }

  // v13 迁移（v1.21.0）：客户档案补全 + 报价状态流转与模板。
  // customers 补 industry/source/location/last_contact_at/updated_at；
  // quotes 补 status/is_template/updated_at。均 PRAGMA 探测防重复。
  Future<void> _migrateToV13(Database db) async {
    final custCols = await db.rawQuery('PRAGMA table_info(customers)');
    if (!custCols.any((c) => c['name'] == 'industry')) {
      await db.execute('ALTER TABLE customers ADD COLUMN industry TEXT');
    }
    if (!custCols.any((c) => c['name'] == 'source')) {
      await db.execute('ALTER TABLE customers ADD COLUMN source TEXT');
    }
    if (!custCols.any((c) => c['name'] == 'location')) {
      await db.execute('ALTER TABLE customers ADD COLUMN location TEXT');
    }
    if (!custCols.any((c) => c['name'] == 'last_contact_at')) {
      await db.execute('ALTER TABLE customers ADD COLUMN last_contact_at INTEGER DEFAULT 0');
    }
    if (!custCols.any((c) => c['name'] == 'updated_at')) {
      await db.execute('ALTER TABLE customers ADD COLUMN updated_at INTEGER');
    }

    final quoteCols = await db.rawQuery('PRAGMA table_info(quotes)');
    if (!quoteCols.any((c) => c['name'] == 'updated_at')) {
      await db.execute('ALTER TABLE quotes ADD COLUMN updated_at INTEGER');
    }
    if (!quoteCols.any((c) => c['name'] == 'status')) {
      await db.execute('ALTER TABLE quotes ADD COLUMN status INTEGER DEFAULT 0');
    }
    if (!quoteCols.any((c) => c['name'] == 'is_template')) {
      await db.execute('ALTER TABLE quotes ADD COLUMN is_template INTEGER DEFAULT 0');
    }
  }

  // v14 迁移（v1.23.0）：迁移机制完善——为高频查询建立索引，提升列表 / 统计看板性能。
  // 全部使用 CREATE INDEX IF NOT EXISTS，幂等且不触碰任何业务数据（不删表、不改行、
  // 不覆盖字段），符合「不得破坏现有业务数据」约束。
  Future<void> _migrateToV14(Database db) async {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_projects_customer ON projects(customer_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_payments_project ON payments(project_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_payments_paid_at ON payments(paid_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_quotes_project ON quotes(project_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_quotes_customer ON quotes(customer_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pending_collections_project ON pending_collections(project_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_milestones_project ON milestones(project_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_contracts_project ON contracts(project_id)');
  }

  // v15 迁移（v1.24.0）：任务/项目跟进 + 报价参考图。
  // projects 补 progress（进度 %）/ deliver_date（交付时间）；quotes 补 image_path（本地参考图路径，
  // 业务数据不上传）。均用 PRAGMA table_info 探测后 ALTER，旧库跨版本升级不重删不丢数。
  Future<void> _migrateToV15(Database db) async {
    final projCols = await db.rawQuery('PRAGMA table_info(projects)');
    if (!projCols.any((c) => c['name'] == 'progress')) {
      await db.execute('ALTER TABLE projects ADD COLUMN progress INTEGER DEFAULT 0');
    }
    if (!projCols.any((c) => c['name'] == 'deliver_date')) {
      await db.execute('ALTER TABLE projects ADD COLUMN deliver_date INTEGER DEFAULT 0');
    }
    final quoteCols = await db.rawQuery('PRAGMA table_info(quotes)');
    if (!quoteCols.any((c) => c['name'] == 'image_path')) {
      await db.execute('ALTER TABLE quotes ADD COLUMN image_path TEXT');
    }
  }

  // v16 迁移（第17批 收款对账）：payments 同时补两列——
  // reconciled：已/未对账标记（0 未对账 / 1 已对账，默认 0）；
  // quote_id：关联报价单 id（可空，未关联时为 NULL）。
  // 沿用 PRAGMA 探测后幂等 ALTER，兼容任意历史版本直接升到 v16。
  Future<void> _migrateToV16(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(payments)');
    if (!cols.any((c) => c['name'] == 'reconciled')) {
      await db
          .execute('ALTER TABLE payments ADD COLUMN reconciled INTEGER DEFAULT 0');
    }
    if (!cols.any((c) => c['name'] == 'quote_id')) {
      await db.execute('ALTER TABLE payments ADD COLUMN quote_id INTEGER');
    }
  }

  // v17 建表：subscription_orders（第15批 订阅订单表，过渡期纯本地闭环）。
  // 记录订阅订单/兑换码激活/邀请送月三类记录，预留云端同步字段 synced / ref_no。
  Future<void> _createSubscriptionOrders(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS subscription_orders(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        phone TEXT,
        plan_key TEXT,
        plan_name TEXT,
        amount INTEGER DEFAULT 0, -- 金额单位：分（兑换码/邀请奖励为 0）
        channel TEXT, -- payment 购买 / redeem 兑换码 / invite 邀请送月
        status TEXT, -- pending 待确认 / paid 已开通 / granted 已发放
        ref_no TEXT, -- 云端订单号 / 兑换码 / 邀请批次（预留）
        synced INTEGER DEFAULT 0, -- 云端同步标记（0 未同步 / 1 已同步，预留）
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
  }

  // v17 迁移（第15批 订阅裂变）：新增 subscription_orders 表。
  // 幂等：PRAGMA table_info 探测表不存在才 CREATE（兼容 v16 老用户直接升级，
  // 以及 CREATE TABLE IF NOT EXISTS 的双重保险；新装走 onCreate 已同步建表）。
  Future<void> _migrateToV17(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(subscription_orders)');
    if (cols.isEmpty) {
      await _createSubscriptionOrders(db);
    }
  }

  // v7 迁移：payments 补 type_label 列（存量置空）+ 新增 quotes 表。
  Future<void> _migrateToV7(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(payments)');
    final hasTypeLabel = cols.any((c) => c['name'] == 'type_label');
    if (!hasTypeLabel) {
      await db.execute('ALTER TABLE payments ADD COLUMN type_label TEXT');
    }
    await _createQuotes(db);
  }

  // v8 迁移：quotes 补 quote_type / note / tax_include 三列。
  // 存量报价单统一标记 'full'（详细报价），tax_include 默认 1，note 置空。
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

  // v9 迁移（金额改分 + 新功能表 + 新列）。
  // SQLite 不支持 ALTER COLUMN 改类型，用「新表 + 复制 x100 + 换名」重建金额表。
  // 涉及金额表：projects / payments / quotes / withdrawals / recharges / invitees；
  // 新增表：pending_collections / milestones / invoices；
  // quotes 增 customer_id，projects 增 due_date / remind_at。
  // 迁移后所有金额字段统一为「分」整数（INTEGER），严禁 double。
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
    final rows = await _all('settings', where: 'key=?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    final d = await db;
    await _guard(() => d.insert(
          'settings',
          {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        ));
  }

  // ============================================================
  // 数据库自检（v1.23.0）：表结构完整性 + 数据可恢复性提示
  //  - 结构完整性：把每张业务表的 PRAGMA table_info 实测列与预期列集合比对，
  //    缺列 / 多余列即告警（不修改任何表结构）；
  //  - 数据可恢复性：integrity_check 检查库文件完整性、foreign_key_check 检查
  //    外键引用合法性，并统计各表行数供用户评估备份必要性。
  // 自检为只读操作，绝不写入业务数据，结果可持久化到 settings 留痕。
  // ============================================================
  static const String kHealthReportKey = 'db_health_last_report';

  Future<DbHealthReport> healthCheck() async {
    final d = await db;
    final report = await _guard(() async {
      final integrityRows = await d.rawQuery('PRAGMA integrity_check(1)');
      final integrityCheck = integrityRows.isEmpty
          ? 'unknown'
          : integrityRows.first.values.first.toString();

      final tables = <TableIntegrity>[];
      final rowCounts = <String, int>{};
      for (final entry in expectedColumns.entries) {
        final cols = await d.rawQuery('PRAGMA table_info(${entry.key})');
        if (cols.isEmpty) {
          tables.add(TableIntegrity(table: entry.key, exists: false));
          continue;
        }
        final actual = cols.map((c) => c['name'].toString()).toSet();
        final missing =
            entry.value.difference(actual).toList()..sort();
        final extra = actual.difference(entry.value).toList()..sort();
        if (missing.isNotEmpty || extra.isNotEmpty) {
          tables.add(TableIntegrity(
            table: entry.key,
            exists: true,
            missingColumns: missing,
            extraColumns: extra,
          ));
        }
        final cnt = await d
            .rawQuery('SELECT COUNT(*) AS c FROM ${entry.key}');
        rowCounts[entry.key] = (cnt.first['c'] as num?)?.toInt() ?? 0;
      }

      final fkRows = await d.rawQuery('PRAGMA foreign_key_check');
      final foreignKeyIssues = fkRows.isEmpty
          ? <String>[]
          : fkRows
              .map((r) =>
                  '${r['table']}#${r['rowid']} -> ${r['parent']}.${r['fkid']}')
              .toList();

      return DbHealthReport(
        checkedAt: DateTime.now(),
        integrityCheck: integrityCheck,
        tables: tables,
        foreignKeyIssues: foreignKeyIssues,
        rowCounts: rowCounts,
      );
    });

    // 留痕最近一次自检结果，供「数据管理」页展示与事后排查。
    try {
      await setSetting(
        kHealthReportKey,
        jsonEncode({
          'checkedAt': report.checkedAt.millisecondsSinceEpoch,
          'healthy': report.healthy,
          'integrity': report.integrityCheck,
          'tables': report.tables
              .map((t) => {
                    'table': t.table,
                    'ok': t.ok,
                    'missing': t.missingColumns,
                    'extra': t.extraColumns,
                  })
              .toList(),
          'rows': report.rowCounts,
        }),
      );
    } catch (_) {
      // 留痕失败不影响自检结果返回。
    }
    return report;
  }

  /// 启动后静默自检：不抛异常、不阻塞启动流程，仅留痕供界面查看。
  Future<void> backgroundHealthCheck() async {
    try {
      await healthCheck();
    } catch (_) {
      // 自检失败不打断启动。
    }
  }

  // ---------- users（本地账号）----------
  Future<UserAccount?> getUserByPhone(String phone) async {
    final r = await _one('users', where: 'phone=?', whereArgs: [phone]);
    return r == null ? null : UserAccount.fromMap(r);
  }

  Future<int> insertUser(UserAccount u) async {
    return _insert('users', u.toMap()..remove('id'));
  }

  Future<void> updateUser(UserAccount u) async {
    await _updateById('users', u.toMap(), u.id!);
  }

  // 当前登录账号（本地会话）
  Future<UserAccount?> getCurrentUser() async {
    final idStr = await getSetting('current_user_id');
    if (idStr == null || idStr.isEmpty) return null;
    final r = await _one('users', where: 'id=?', whereArgs: [int.tryParse(idStr)]);
    return r == null ? null : UserAccount.fromMap(r);
  }

  Future<void> setCurrentUser(int? id) async {
    if (id == null) {
      await setSetting('current_user_id', '');
    } else {
      await setSetting('current_user_id', '$id');
    }
  }

  // ---------- customers（同步表）----------
  Future<List<Customer>> getCustomers() async {
    final rows = await _all('customers', orderBy: 'created_at DESC');
    return rows.map(Customer.fromMap).toList();
  }

  Future<int> insertCustomer(Customer c) async {
    return _insertSync('customers', c.toMap()..remove('id'));
  }

  Future<void> updateCustomer(Customer c) async {
    await _updateSyncById('customers', c.toMap(), c.id!);
  }

  // v1.21.0 客户累计收款统计（payments join projects 按客户聚合）。
  // 返回 Map<customerId, 累计收款额(分)>；无项目或未入款的客户不计入。
  Future<Map<int, int>> customerPaidTotals() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT pr.customer_id AS cid, COALESCE(SUM(py.amount), 0) AS amt
      FROM payments py
      JOIN projects pr ON py.project_id = pr.id
      WHERE pr.customer_id IS NOT NULL
      GROUP BY pr.customer_id
    ''');
    final result = <int, int>{};
    for (final r in rows) {
      final cid = r['cid'] as int?;
      final amt = r['amt'] as num?;
      if (cid != null) result[cid] = amt?.toInt() ?? 0;
    }
    return result;
  }

  // 单个客户累计收款（分）。
  Future<int> customerPaidTotal(int customerId) async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT COALESCE(SUM(py.amount), 0) AS amt
      FROM payments py
      JOIN projects pr ON py.project_id = pr.id
      WHERE pr.customer_id = ?
    ''', [customerId]);
    return ((rows.isNotEmpty ? rows.first['amt'] : 0) as num?)?.toInt() ?? 0;
  }

  // 级联删除：先删该客户全部项目（deleteProject 已级联子表），再删待收/报价，最后删客户。
  Future<void> deleteCustomer(int id) async {
    final projects =
        await _all('projects', where: 'customer_id=?', whereArgs: [id]);
    for (final pr in projects) {
      await deleteProject(pr['id'] as int);
    }
    final pendings =
        await _all('pending_collections', where: 'customer_id=?', whereArgs: [id]);
    for (final pc in pendings) {
      await addTombstone('pending_collections', pc['id'] as int);
    }
    final quotes = await _all('quotes', where: 'customer_id=?', whereArgs: [id]);
    for (final q in quotes) {
      await addTombstone('quotes', q['id'] as int);
    }
    await _deleteByWhere('pending_collections',
        where: 'customer_id=?', whereArgs: [id]);
    await _deleteByWhere('quotes', where: 'customer_id=?', whereArgs: [id]);
    await _deleteById('customers', id, strict: false);
    await addTombstone('customers', id);
    _notify();
  }

  // ---------- projects（同步表）----------
  Future<List<Project>> getProjects() async {
    final rows = await _all('projects', orderBy: 'updated_at DESC');
    return rows.map(Project.fromMap).toList();
  }

  Future<List<Project>> getProjectsByCustomer(int customerId) async {
    final rows = await _all('projects',
        where: 'customer_id=?', whereArgs: [customerId]);
    return rows.map(Project.fromMap).toList();
  }

  Future<int> insertProject(Project pr) async {
    return _insertSync('projects', pr.toMap()..remove('id'));
  }

  Future<void> updateProject(Project pr) async {
    await _updateSyncById('projects', pr.toMap(), pr.id!);
  }

  // 级联删除：删 payments/里程碑/待收/发票/合同/报价，再删项目本身。
  Future<void> deleteProject(int id) async {
    final pms =
        await _all('payments', where: 'project_id=?', whereArgs: [id]);
    for (final r in pms) {
      await addTombstone('payments', r['id'] as int);
    }
    final ms =
        await _all('milestones', where: 'project_id=?', whereArgs: [id]);
    for (final r in ms) {
      await addTombstone('milestones', r['id'] as int);
    }
    final pcs = await _all('pending_collections',
        where: 'project_id=?', whereArgs: [id]);
    for (final r in pcs) {
      await addTombstone('pending_collections', r['id'] as int);
    }
    final cts =
        await _all('contracts', where: 'project_id=?', whereArgs: [id]);
    for (final r in cts) {
      await addTombstone('contracts', r['id'] as int);
    }
    final qs = await _all('quotes', where: 'project_id=?', whereArgs: [id]);
    for (final r in qs) {
      await addTombstone('quotes', r['id'] as int);
    }
    await _deleteByWhere('payments', where: 'project_id=?', whereArgs: [id]);
    await _deleteByWhere('milestones', where: 'project_id=?', whereArgs: [id]);
    await _deleteByWhere('pending_collections',
        where: 'project_id=?', whereArgs: [id]);
    // v10 起 invoices 表已被 contracts 替代并 DROP，此处不得再引用该表
    // （否则新版数据库删除项目时会因表不存在抛异常，导致删除中断）。
    await _deleteByWhere('contracts', where: 'project_id=?', whereArgs: [id]);
    await _deleteByWhere('quotes', where: 'project_id=?', whereArgs: [id]);
    await _deleteById('projects', id, strict: false);
    await addTombstone('projects', id);
    _notify();
  }

  // ---------- payments（同步表）----------
  Future<List<Payment>> getPayments(int projectId) async {
    final rows = await _all('payments',
        where: 'project_id=?',
        whereArgs: [projectId],
        orderBy: 'paid_at ASC');
    return rows.map(Payment.fromMap).toList();
  }

  Future<int> insertPayment(Payment pay) async {
    return _insertSync('payments', pay.toMap()..remove('id'));
  }

  Future<void> deletePayment(int id) async {
    await _deleteSyncById('payments', id);
  }

  // 项目已收总额，单位分
  Future<int> projectPaidTotal(int projectId) async {
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
          'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE project_id=?',
          [projectId],
        ));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 全部项目已收总额（列表页一次取齐，避免逐项目查询），值单位分
  Future<Map<int, int>> projectPaidTotals() async {
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
        'SELECT project_id, COALESCE(SUM(amount),0) AS t FROM payments GROUP BY project_id'));
    return {
      for (final r in rows)
        r['project_id'] as int: (r['t'] as num?)?.toInt() ?? 0,
    };
  }

  // 本月收入，单位分
  Future<int> monthPaidTotal(int year, int month) async {
    final d = await db;
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    final rows = await _guard(() => d.rawQuery(
          'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
          [start, end],
        ));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 指定月份全部收款明细（含项目标题），按收款时间倒序
  Future<List<Map<String, Object?>>> monthPayments(int year, int month) async {
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    return paymentsInRange(start, end);
  }

  // 任意时间段收入合计（年/月/周/自定义区间共用），值单位分
  Future<int> paidTotalInRange(int startMs, int endMs) async {
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
          'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
          [startMs, endMs],
        ));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 任意时间段全部收款明细（含项目标题），按收款时间倒序
  Future<List<Map<String, Object?>>> paymentsInRange(
      int startMs, int endMs) async {
    final d = await db;
    return _guard(() => d.rawQuery(
          'SELECT p.*, COALESCE(pr.title, \'已删除项目\') AS project_title '
          'FROM payments p LEFT JOIN projects pr ON pr.id = p.project_id '
          'WHERE p.paid_at>=? AND p.paid_at<? '
          'ORDER BY p.paid_at DESC',
          [startMs, endMs],
        ));
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
      final rows = await _guard(() => d.rawQuery(
            'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE paid_at>=? AND paid_at<?',
            [start, end],
          ));
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
    return _guard(() => d.rawQuery('''
      SELECT COALESCE(c.name, '未关联客户') AS customer_name,
             COALESCE(SUM(p.amount),0) AS total
      FROM payments p
      LEFT JOIN projects pr ON pr.id = p.project_id
      LEFT JOIN customers c ON c.id = pr.customer_id
      GROUP BY COALESCE(c.name, '未关联客户')
      ORDER BY total DESC
    '''));
  }

  // 待收总额（分）：所有 status=pending 的待收款合计
  Future<int> pendingTotal() async {
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM pending_collections WHERE status=?',
        [PendingStatus.pending.index]));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 收款 / 待收构成：已收总额 与 待收总额，均单位分
  Future<Map<String, int>> paidVsPendingSummary() async {
    final paid = await allPaidTotal();
    final pending = await pendingTotal();
    return {'paid': paid, 'pending': pending};
  }

  // v1.22.0 有效报价总额（分）：仅统计 已发送/客户确认/已成交 三个业务态，
  // 草稿(draft)与作废(voided)不参与收入统计，模板(is_template=1)也不参与。
  // 可选时间范围（按报价创建时间 created_at，startMs/endMs 传 0 表示不限）。
  Future<int> quotesTotalInRange({int startMs = 0, int endMs = 0}) async {
    final d = await db;
    final cond = StringBuffer('WHERE is_template=0 AND status IN (?,?,?)');
    final args = <Object?>[
      QuoteStatus.sent.index,
      QuoteStatus.confirmed.index,
      QuoteStatus.deal.index,
    ];
    if (startMs > 0) {
      cond.write(' AND created_at>=?');
      args.add(startMs);
    }
    if (endMs > 0) {
      cond.write(' AND created_at<?');
      args.add(endMs);
    }
    final rows = await _guard(() => d.rawQuery(
          'SELECT COALESCE(SUM(total),0) AS t FROM quotes $cond',
          args,
        ));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // v1.22.0 按报价类型分类汇总有效报价金额（简单 simple / 详细 full），
  // 分类汇总口径同 quotesTotalInRange：排除草稿/作废/模板。
  Future<List<Map<String, Object?>>> quotesByTypeInRange(
      {int startMs = 0, int endMs = 0}) async {
    final d = await db;
    final cond = StringBuffer('is_template=0 AND status IN (?,?,?)');
    final args = <Object?>[
      QuoteStatus.sent.index,
      QuoteStatus.confirmed.index,
      QuoteStatus.deal.index,
    ];
    if (startMs > 0) {
      cond.write(' AND created_at>=?');
      args.add(startMs);
    }
    if (endMs > 0) {
      cond.write(' AND created_at<?');
      args.add(endMs);
    }
    return _guard(() => d.rawQuery(
          'SELECT quote_type AS type, COALESCE(SUM(total),0) AS total '
          'FROM quotes WHERE $cond GROUP BY quote_type',
          args,
        ));
  }

  // v1.22.0 指定时间段内收入按客户分类汇总（分）。
  // 基于 payments.paid_at 过滤，客户归属沿用「收款→项目→客户」链路。
  Future<List<Map<String, Object?>>> customerContributionInRange(
      int startMs, int endMs) async {
    final d = await db;
    return _guard(() => d.rawQuery('''
      SELECT COALESCE(c.name, '未关联客户') AS customer_name,
             COALESCE(SUM(p.amount),0) AS total
      FROM payments p
      LEFT JOIN projects pr ON pr.id = p.project_id
      LEFT JOIN customers c ON c.id = pr.customer_id
      WHERE p.paid_at>=? AND p.paid_at<?
      GROUP BY COALESCE(c.name, '未关联客户')
      ORDER BY total DESC
    ''', [startMs, endMs]));
  }

  // v1.22.0 指定时间段内收入按项目阶段分类汇总（分）。
  // 项目阶段取 projects.status（接单/制作中/待收尾款/完结），已删除项目归「其他」，
  // 作为统计看板「按项目」分类汇总维度（项目目前无独立类型字段）。
  Future<List<Map<String, Object?>>> incomeByProjectStatus(
      int startMs, int endMs) async {
    final d = await db;
    return _guard(() => d.rawQuery('''
      SELECT pr.status AS status, COALESCE(SUM(p.amount),0) AS total
      FROM payments p
      LEFT JOIN projects pr ON pr.id = p.project_id
      WHERE p.paid_at>=? AND p.paid_at<?
      GROUP BY pr.status
      ORDER BY total DESC
    ''', [startMs, endMs]));
  }

  // 对账汇总：每个项目 约定总额/已收/待收（均分）
  Future<List<Map<String, Object?>>> reconciliationSummary() async {
    final d = await db;
    return _guard(() => d.rawQuery('''
      SELECT pr.id AS project_id,
             COALESCE(pr.title, '已删除项目') AS project_title,
             COALESCE(c.name, '未关联客户') AS customer_name,
             COALESCE(pr.amount_total,0) AS amount_total,
             COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.project_id = pr.id),0) AS paid_total,
             COALESCE((SELECT SUM(pc.amount) FROM pending_collections pc WHERE pc.project_id = pr.id AND pc.status = 0),0) AS pending_total
      FROM projects pr
      LEFT JOIN customers c ON c.id = pr.customer_id
      ORDER BY pr.updated_at DESC
    '''));
  }

  // ---------- 第17批 收款对账增强（v1.28.0 / db v16）----------
  // 全量收款流水明细（含项目/客户/关联报价标题），按收款时间倒序。
  // reconciled 传 null=全部、true=仅未对账、false=仅已对账。
  Future<List<Map<String, Object?>>> reconciliationFlows(
      {bool? reconciled}) async {
    final d = await db;
    final sb = StringBuffer(
      'SELECT p.*, '
      "COALESCE(pr.title, '已删除项目') AS project_title, "
      "COALESCE(c.name, '未关联客户') AS customer_name, "
      "COALESCE(q.title, '') AS quote_title "
      'FROM payments p '
      'LEFT JOIN projects pr ON pr.id = p.project_id '
      'LEFT JOIN customers c ON c.id = pr.customer_id '
      'LEFT JOIN quotes q ON q.id = p.quote_id',
    );
    final args = <Object?>[];
    if (reconciled != null) {
      sb.write(' WHERE p.reconciled = ?');
      args.add(reconciled ? 1 : 0);
    }
    sb.write(' ORDER BY p.paid_at DESC');
    return _guard(() => d.rawQuery(sb.toString(), args));
  }

  // 指定报价单关联的全部收款流水（从报价单看已收），按收款时间倒序。
  Future<List<Map<String, Object?>>> paymentsByQuote(int quoteId) async {
    final d = await db;
    return _guard(() => d.rawQuery(
          'SELECT p.*, '
          "COALESCE(pr.title, '已删除项目') AS project_title "
          'FROM payments p LEFT JOIN projects pr ON pr.id = p.project_id '
          'WHERE p.quote_id=? ORDER BY p.paid_at DESC',
          [quoteId],
        ));
  }

  // 指定报价单已收合计（分）：基于 quote_id 精确关联。
  Future<int> quotePaidTotal(int quoteId) async {
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
          'SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE quote_id=?',
          [quoteId],
        ));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 切换收款流水对账标记（0 未对账 / 1 已对账）。
  Future<void> setPaymentReconciled(int id, bool reconciled) async {
    await _updateByWhere(
      'payments',
      {'reconciled': reconciled ? 1 : 0},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  // 有待收提醒设置的项目（due_date>0 且存在未结清待收）
  Future<List<Map<String, Object?>>> projectsWithPendingReminder() async {
    final d = await db;
    return _guard(() => d.rawQuery('''
      SELECT pr.id AS project_id, pr.title AS project_title, pr.due_date,
             COALESCE((SELECT SUM(pc.amount) FROM pending_collections pc WHERE pc.project_id = pr.id AND pc.status = 0),0) AS pending_total
      FROM projects pr
      WHERE pr.due_date > 0
        AND EXISTS(SELECT 1 FROM pending_collections pc WHERE pc.project_id = pr.id AND pc.status = 0)
    '''));
  }

  // ---------- quotes（报价单历史 v7，同步表）----------
  // v1.21.0 起业务列表与统计默认不含模板（is_template=1 的仅用于模板套用）。
  Future<List<Quote>> getQuotes() async {
    final rows = await _all('quotes',
        where: 'is_template=?', whereArgs: [0], orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  Future<List<Quote>> getQuotesByCustomer(int customerId) async {
    final rows = await _all('quotes',
        where: 'customer_id=?',
        whereArgs: [customerId],
        orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  Future<List<Quote>> getQuotesByProject(int projectId) async {
    final rows = await _all('quotes',
        where: 'project_id=?',
        whereArgs: [projectId],
        orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  // v1.21.0 模板列表：仅返回 is_template=1 的模板（不含普通报价单）。
  Future<List<Quote>> getQuoteTemplates() async {
    final rows = await _all('quotes',
        where: 'is_template=?', whereArgs: [1], orderBy: 'created_at DESC');
    return rows.map(Quote.fromMap).toList();
  }

  // v1.21.0 快速状态流转：仅改 status 与 updated_at，走同步通道通知刷新。
  Future<void> updateQuoteStatus(int id, QuoteStatus status) async {
    await _updateByWhere(
      'quotes',
      {
        'status': status.index,
        'updated_at': now(),
      },
      where: 'id=?',
      whereArgs: [id],
    );
    _notify();
  }

  Future<int> insertQuote(Quote q) async {
    return _insertSync('quotes', q.toMap()..remove('id'));
  }

  Future<void> updateQuote(Quote q) async {
    await _updateSyncById('quotes', q.toMap(), q.id!);
  }

  Future<void> deleteQuote(int id) async {
    await _deleteSyncById('quotes', id);
  }

  // ---------- pending_collections（待收款 v9，同步表）----------
  Future<List<PendingCollection>> getPendingCollections(
      {bool onlyPending = false}) async {
    final rows = onlyPending
        ? await _all('pending_collections',
            where: 'status=?',
            whereArgs: [PendingStatus.pending.index],
            orderBy: 'created_at DESC')
        : await _all('pending_collections', orderBy: 'created_at DESC');
    return rows.map(PendingCollection.fromMap).toList();
  }

  Future<int> insertPendingCollection(PendingCollection pc) async {
    return _insertSync('pending_collections', pc.toMap()..remove('id'));
  }

  Future<void> updatePendingCollection(PendingCollection pc) async {
    await _updateSyncById('pending_collections', pc.toMap(), pc.id!);
  }

  Future<void> settlePending(int id) async {
    await _updateByWhere(
      'pending_collections',
      {
        'status': PendingStatus.done.index,
        'settled_at': now(),
        'updated_at': now(),
      },
      where: 'id=?',
      whereArgs: [id],
    );
    _notify();
  }

  Future<void> deletePendingCollection(int id) async {
    await _deleteSyncById('pending_collections', id);
  }

  // ---------- milestones（项目里程碑 v9，同步表）----------
  Future<List<Milestone>> getMilestones(int projectId) async {
    final rows = await _all('milestones',
        where: 'project_id=?', whereArgs: [projectId], orderBy: 'created_at ASC');
    return rows.map(Milestone.fromMap).toList();
  }

  Future<int> insertMilestone(Milestone ms) async {
    return _insertSync('milestones', ms.toMap()..remove('id'));
  }

  Future<void> updateMilestone(Milestone ms) async {
    await _updateSyncById('milestones', ms.toMap(), ms.id!);
  }

  Future<void> deleteMilestone(int id) async {
    await _deleteSyncById('milestones', id);
  }

  // ---------- contracts（合同/协议 v10，同步表）----------
  Future<List<Contract>> getContracts() async {
    final rows = await _all('contracts', orderBy: 'signed_at DESC');
    return rows.map(Contract.fromMap).toList();
  }

  Future<int> insertContract(Contract c) async {
    return _insertSync('contracts', c.toMap()..remove('id'));
  }

  Future<void> updateContract(Contract c) async {
    await _updateSyncById('contracts', c.toMap(), c.id!);
  }

  Future<void> deleteContract(int id) async {
    await _deleteSyncById('contracts', id);
  }

  // ---------- feedbacks（意见反馈）----------
  // 插入一条本地反馈。[serverId] 服务器反馈 id（便于合并作者回复）；
  // [synced] 1=已提交服务器，0=仅本地草稿（网络失败自动标记）。
  Future<int> insertFeedback({
    required int type,
    required String content,
    String contact = '',
    int? serverId,
    int synced = 1,
  }) async {
    return _insert('feedbacks', {
      'type': type,
      'content': content,
      'contact': contact,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'server_id': serverId,
      'synced': synced,
    });
  }

  Future<List<Map<String, Object?>>> getFeedbacks() async {
    return _all('feedbacks', orderBy: 'created_at DESC');
  }

  // 按服务器反馈 id 更新回复信息与同步状态（离线合并作者回复）。
  Future<void> updateFeedbackReply({
    required int serverId,
    String? reply,
    int? repliedAt,
    int? synced,
  }) async {
    final data = <String, Object?>{
      'reply': ?reply,
      'replied_at': ?repliedAt,
      'synced': ?synced,
    };
    await _updateByWhere('feedbacks', data,
        where: 'server_id=?', whereArgs: [serverId]);
  }

  // 将服务器 /api/feedback/mine 返回的一条反馈合并进本地反馈箱：
  // - 已存在（按 server_id 匹配）：仅刷新作者回复，以服务器回复为准，不回写本地编辑内容；
  // - 不存在：以服务器数据为准新增（记录 server_id 便于后续匹配）。
  Future<void> upsertFeedbackFromServer({
    int? serverId,
    required int type,
    required String content,
    String contact = '',
    required int createdAt,
    String? reply,
    int? repliedAt,
  }) async {
    if (serverId != null) {
      final exist =
          await _one('feedbacks', where: 'server_id=?', whereArgs: [serverId]);
      if (exist != null) {
        final data = <String, Object?>{
          'reply': ?reply,
          'replied_at': ?repliedAt,
          if (reply != null || repliedAt != null) 'synced': 1,
        };
        await _updateByWhere('feedbacks', data,
            where: 'server_id=?', whereArgs: [serverId]);
        return;
      }
    }
    // 新增服务器条目（本地可能无对应记录，例如跨设备登录后同步）
    await _insert('feedbacks', {
      'type': type,
      'content': content,
      'contact': contact,
      'created_at': createdAt,
      'server_id': serverId,
      'reply': reply,
      'replied_at': repliedAt,
      'synced': 1,
    });
  }

  // ---------- invitees（推广活动 - 被邀请人）----------
  Future<List<Invitee>> getInvitees(int inviterUserId) async {
    final rows = await _all('invitees',
        where: 'inviter_user_id=?',
        whereArgs: [inviterUserId],
        orderBy: 'invited_at DESC');
    return rows.map(Invitee.fromMap).toList();
  }

  Future<int> insertInvitee(Invitee inv) async {
    return _insert('invitees', inv.toMap()..remove('id'));
  }

  Future<void> updateInvitee(Invitee inv) async {
    await _updateById('invitees', inv.toMap(), inv.id!);
  }

  Future<void> deleteInvitee(int id) async {
    await _deleteById('invitees', id);
  }

  // ---------- 推广活动 - 邀请码（本地生成，存 settings）----------
  // 读取我的邀请码；不存在则生成并落库。规则：JD + 4 位（1000+userId），稳定可读。
  Future<String> getOrCreateInviteCode(int userId) async {
    final key = 'invite_code_$userId';
    final exist = await getSetting(key);
    if (exist != null && exist.isNotEmpty) return exist;
    final code = 'JD${1000 + userId}';
    await setSetting(key, code);
    return code;
  }

  // 我注册时填写的邀请码（来自哪位邀请人），存 settings
  Future<String?> getMyInviterCode() => getSetting('my_inviter_code');
  Future<void> setMyInviterCode(String code) =>
      setSetting('my_inviter_code', code);

  // ---------- 收款码（微信 / 支付宝二维码图片路径）----------
  Future<String?> getWxQrPath() => getSetting('wx_qr_path');
  Future<void> setWxQrPath(String path) => setSetting('wx_qr_path', path);
  Future<String?> getAliQrPath() => getSetting('ali_qr_path');
  Future<void> setAliQrPath(String path) => setSetting('ali_qr_path', path);

  // ---------- 第15批 订阅订单（subscription_orders，过渡期本地闭环）----------
  // 订阅渠道（channel）与状态（status）常量。
  static const String subChannelPayment = 'payment'; // 购买（手动收款上报）
  static const String subChannelRedeem = 'redeem'; // 兑换码激活
  static const String subChannelInvite = 'invite'; // 邀请送月
  static const String subStatusPending = 'pending'; // 待确认（已提交待人工核）
  static const String subStatusPaid = 'paid'; // 已开通（已确认到账）
  static const String subStatusGranted = 'granted'; // 已发放（兑换码/邀请送月已落地）

  // 插入一条订阅订单记录，返回自增 id。
  Future<int> insertSubscriptionOrder({
    required int userId,
    String phone = '',
    String planKey = '',
    String planName = '',
    int amount = 0,
    String channel = subChannelPayment,
    String status = subStatusPending,
    String refNo = '',
    int synced = 0,
  }) async {
    final t = DateTime.now().millisecondsSinceEpoch;
    return _insert('subscription_orders', {
      'user_id': userId,
      'phone': phone,
      'plan_key': planKey,
      'plan_name': planName,
      'amount': amount,
      'channel': channel,
      'status': status,
      'ref_no': refNo,
      'synced': synced,
      'created_at': t,
      'updated_at': t,
    });
  }

  // 我的订阅订单明细（按时间倒序）。
  Future<List<Map<String, Object?>>> subscriptionOrders(int userId) async {
    return _all('subscription_orders',
        where: 'user_id=?', whereArgs: [userId], orderBy: 'created_at DESC');
  }

  // 某用户指定渠道/状态的订阅订单数（兑换码去重、防止重复发放等）。
  Future<int> subscriptionOrderCount({
    required int userId,
    String? channel,
    String? status,
  }) async {
    final cond = StringBuffer('user_id=?');
    final args = <Object?>[userId];
    if (channel != null) {
      cond.write(' AND channel=?');
      args.add(channel);
    }
    if (status != null) {
      cond.write(' AND status=?');
      args.add(status);
    }
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
        'SELECT COUNT(*) AS c FROM subscription_orders WHERE $cond', args));
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  // ---------- 推广赠送 VIP 状态（避免重复赠送）----------
  Future<bool> inviteBonusGranted(int userId) async {
    final v = await getSetting('invite_bonus_granted_$userId');
    return v == '1';
  }

  Future<void> markInviteBonusGranted(int userId) =>
      setSetting('invite_bonus_granted_$userId', '1');

  // ---------- 钱包 / 提现（v5）----------

  // 全部已收总额（所有 payments 合计），单位分
  Future<int> allPaidTotal() async {
    final d = await db;
    final rows = await _guard(
        () => d.rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM payments'));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 已提交提现总额（含待处理/处理中/已提现，均占用可提现额度），单位分
  Future<int> totalWithdrawn() async {
    final d = await db;
    final rows = await _guard(
        () => d.rawQuery('SELECT COALESCE(SUM(amount),0) AS t FROM withdrawals'));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 已确认到账的充值总额（仅 status=done），单位分
  Future<int> totalRecharged() async {
    final d = await db;
    final rows = await _guard(() => d.rawQuery(
        'SELECT COALESCE(SUM(amount),0) AS t FROM recharges WHERE status=?',
        [RechargeStatus.done.index]));
    return (rows.first['t'] as num?)?.toInt() ?? 0;
  }

  // 可提现余额（分）= 累计收款 + 累计充值到账 - 已提交提现
  Future<int> withdrawableBalance() async {
    final paid = await allPaidTotal();
    final recharged = await totalRecharged();
    final withdrawn = await totalWithdrawn();
    final v = paid + recharged - withdrawn;
    return v < 0 ? 0 : v;
  }

  Future<int> insertRecharge(Recharge r) async {
    return _insert('recharges', r.toMap()..remove('id'));
  }

  Future<List<Recharge>> getRecharges() async {
    final rows = await _all('recharges', orderBy: 'created_at DESC');
    return rows.map(Recharge.fromMap).toList();
  }

  Future<void> updateRecharge(Recharge r) async {
    await _updateById('recharges', r.toMap(), r.id!);
  }

  Future<int> insertWithdrawal(Withdrawal w) async {
    return _insert('withdrawals', w.toMap()..remove('id'));
  }

  Future<List<Withdrawal>> getWithdrawals() async {
    final rows = await _all('withdrawals', orderBy: 'created_at DESC');
    return rows.map(Withdrawal.fromMap).toList();
  }

  Future<void> updateWithdrawal(Withdrawal w) async {
    await _updateById('withdrawals', w.toMap(), w.id!);
  }

  // 读取已保存的提现账户
  Future<WithdrawAccount> getWithdrawAccount() async {
    final raw = await getSetting(AppConfig.withdrawAccountKey);
    return WithdrawAccount.fromJson(raw);
  }

  Future<void> setWithdrawAccount(WithdrawAccount acc) =>
      setSetting(AppConfig.withdrawAccountKey, acc.toJson());

  // ---------- 云端同步辅助（v1.14.0，存储方式三选一）----------

  // 记录一条删除墓碑（不触发数据变更通知，避免同步应用路径回调循环）。
  Future<void> addTombstone(String table, int id) async {
    await _insert('sync_tombstones', {
      'table_name': table,
      'row_id': id,
      'deleted_at': now(),
    });
  }

  // 读取某同步表的全部原始行（供上传 / 合并）。
  Future<List<Map<String, Object?>>> syncRows(String table) async {
    return _all(table);
  }

  // 按 id 读取某同步表的一行（供冲突比较）；不存在返回 null。
  Future<Map<String, Object?>?> syncRowById(String table, int id) async {
    return _one(table, where: 'id=?', whereArgs: [id]);
  }

  // 按主键 upsert 一行服务器下发的数据（剥离内部字段 _ts / _deleted）。
  // 不触发数据变更通知（同步回写不应再次触发推送）。
  Future<void> upsertSyncRow(String table, Map<String, Object?> row) async {
    final clean = Map<String, Object?>.from(row)
      ..remove('_ts')
      ..remove('_deleted');
    final id = clean['id'];
    if (id == null) return;
    final d = await db;
    await _guard(() => d.insert(
          table,
          clean,
          conflictAlgorithm: ConflictAlgorithm.replace,
        ));
  }

  // 静默删除一行（同步应用服务器删除时使用，不再产生墓碑）。
  Future<void> deleteRowSilently(String table, int id) async {
    await _deleteById(table, id, strict: false);
  }

  // 全部待上传墓碑（table_name / row_id / deleted_at）。
  Future<List<Map<String, Object?>>> getTombstones() async {
    return _all('sync_tombstones', orderBy: 'deleted_at ASC');
  }

  // 推送成功后清空墓碑。
  Future<void> clearTombstones() async {
    final d = await db;
    await _guard(() => d.delete('sync_tombstones'));
  }

  // 各同步表行数（切换存储方式 / 首次上传时的数据量展示）。
  Future<Map<String, int>> syncTableCounts() async {
    final tables = [
      'customers',
      'projects',
      'payments',
      'quotes',
      'pending_collections',
      'milestones',
      'contracts',
    ];
    final d = await db;
    final counts = <String, int>{};
    for (final t in tables) {
      final rows = await _guard(() => d.rawQuery('SELECT COUNT(*) AS c FROM $t'));
      counts[t] = (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    return counts;
  }
}

// ============================================================
// 数据库自检 - 预期表结构（v1.23.0）
// 每张业务表的「完整合法列集合」，供 healthCheck() 与 PRAGMA table_info 实测结果比对。
// 注意：新增表 / 新增列时必须同步维护本集合与对应迁移函数，避免自检误报缺列。
// ============================================================
const Map<String, Set<String>> expectedColumns = {
  'customers': {
    'id', 'name', 'contact', 'note', 'industry', 'source', 'location',
    'last_contact_at', 'created_at', 'updated_at',
  },
  'projects': {
    'id', 'customer_id', 'title', 'status', 'amount_total', 'created_at',
    'updated_at', 'due_date', 'remind_at', 'progress', 'deliver_date',
  },
  'payments': {
    'id', 'project_id', 'amount', 'type', 'type_label', 'paid_at', 'note',
    'reconciled', 'quote_id',
  },
  'settings': {'key', 'value'},
  'users': {
    'id', 'phone', 'pass_hash', 'nickname', 'is_pro', 'pro_expire_at',
    'created_at',
  },
  'feedbacks': {
    'id', 'type', 'content', 'contact', 'created_at', 'server_id', 'reply',
    'replied_at', 'synced',
  },
  'invitees': {
    'id', 'inviter_user_id', 'name', 'phone', 'invited_at', 'paid',
    'pay_amount', 'rebate', 'paid_at',
  },
  'withdrawals': {
    'id', 'amount', 'method', 'account_name', 'account_no', 'status',
    'created_at', 'note',
  },
  'recharges': {'id', 'amount', 'method', 'status', 'created_at', 'note'},
  'quotes': {
    'id', 'project_id', 'customer_id', 'title', 'tax_rate', 'lines_json',
    'total', 'created_at', 'quote_type', 'note', 'tax_include', 'status',
    'is_template', 'updated_at', 'image_path',
  },
  'pending_collections': {
    'id', 'project_id', 'quote_id', 'customer_id', 'title', 'amount',
    'due_date', 'status', 'created_at', 'settled_at',
  },
  'milestones': {'id', 'project_id', 'name', 'amount', 'done', 'created_at'},
  'contracts': {
    'id', 'target', 'amount', 'project_id', 'status', 'signed_at',
    'contract_no', 'note',
  },
  'sync_tombstones': {'id', 'table_name', 'row_id', 'deleted_at'},
  'subscription_orders': {
    'id', 'user_id', 'phone', 'plan_key', 'plan_name', 'amount', 'channel',
    'status', 'ref_no', 'synced', 'created_at', 'updated_at',
  },
};

/// 单表结构完整性检查结果。
class TableIntegrity {
  const TableIntegrity({
    required this.table,
    required this.exists,
    this.missingColumns = const [],
    this.extraColumns = const [],
  });

  final String table;
  final bool exists;
  final List<String> missingColumns;
  final List<String> extraColumns;

  bool get ok => exists && missingColumns.isEmpty && extraColumns.isEmpty;

  String get describe {
    if (!exists) return '表缺失';
    if (missingColumns.isNotEmpty) return '缺列: ${missingColumns.join(', ')}';
    if (extraColumns.isNotEmpty) return '多余列: ${extraColumns.join(', ')}';
    return '完整';
  }
}

/// 数据库自检报告（表结构完整性 + 数据可恢复性提示）。
class DbHealthReport {
  const DbHealthReport({
    required this.checkedAt,
    required this.integrityCheck,
    required this.tables,
    required this.foreignKeyIssues,
    required this.rowCounts,
  });

  final DateTime checkedAt;

  /// PRAGMA integrity_check(1) 结果：'ok' 表示库文件完整，否则为具体损坏信息。
  final String integrityCheck;

  /// 存在异常的表的检查结果；结构完全正常的表不在此列表。
  final List<TableIntegrity> tables;

  /// foreign_key_check 查出的外键引用问题（空列表 = 无问题）。
  final List<String> foreignKeyIssues;

  /// 各表行数（仅统计存在且可读的表）。
  final Map<String, int> rowCounts;

  bool get healthy =>
      integrityCheck == 'ok' &&
      foreignKeyIssues.isEmpty &&
      tables.every((t) => t.ok);

  int get totalRows => rowCounts.values.fold(0, (sum, n) => sum + n);
}
