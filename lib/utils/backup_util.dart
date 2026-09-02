import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../database.dart';
import '../models.dart';

/// ====================================================================
/// 数据备份工具：JSON 全量备份 / 本地数据恢复。
///
/// 【备份范围】备份全部业务用户数据，共七张业务表：
///   - quotes（报价单）
///   - customers（客户）
///   - projects（项目）
///   - payments（收款记录）
///   - pending_collections（待收款）
///   - milestones（项目里程碑）
///   - contracts（合同/协议）
/// 全部记录经现有 model 的 toMap() 序列化为 JSON 数组；恢复时先清空这七张
/// 业务表再按备份内容覆盖写入，保证「备份=当前库」镜像一致，杜绝旧数据残留。
/// 不导出云端同步状态标记、token、登录会话及应用运行时状态。
///
/// 【备份文件结构】
/// {
///   "exportVersion": "1.1",          // 格式版本，用于将来兼容判断
///   "exportAt": "2026-09-02T...",    // 导出时间戳
///   "data": {
///     "quotes": [...], "customers": [...], "projects": [...],
///     "payments": [...], "pending_collections": [...],
///     "milestones": [...], "contracts": [...]
///   }
/// }
///
/// 【版本兼容】v1.0（仅三表）与 v1.1（七表）均可导入：
///   旧版 v1.0 文件缺少后四张扩展表时，按空数据处理，不阻断导入。
///
/// 【恢复策略（高风险，覆盖模式）】
/// 开启数据库事务 → 按子表先删的顺序清空七张业务表 → 按父表先插的顺序
/// 批量插入备份内全部记录 → 事务提交；任意一步出错整体回滚，绝不残留半份数据。
/// 恢复只操作本地业务数据，不触碰云端同步逻辑，不会自动上传/删除服务器数据。
/// 如用户开启了云端同步，恢复完成后需手动触发一次同步。
///
/// 【风险提示】恢复会覆盖当前手机上的全部业务数据且不可撤销，
/// 调用方（UI 层）必须提供双层确认后再调用 [restoreFromFile]。
/// ====================================================================
class BackupUtil {
  BackupUtil._();
  static final BackupUtil instance = BackupUtil._();

  /// 备份格式版本。将来若调整 JSON 结构（新增表/字段）需递增该版本号，
  /// 新版本需在老版本基础上向后兼容（见 [kSupportedVersions]）。
  static const String kBackupVersion = '1.1';

  /// 可导入的历史版本集合：v1.0（三表）/ v1.1（七表）。
  static const Set<String> kSupportedVersions = {'1.0', '1.1'};

  /// 导出文件名前缀。
  static const String kFileNamePrefix = '接单管家_备份_';

  /// 一次导出七张业务表全部数据，生成 JSON 全量备份，返回文件完整路径。
  /// 导出成功后再由 UI 层通过系统分享面板让用户保存到下载/网盘/微信。
  Future<String> exportAll() async {
    final db = AppDb.instance;
    final raw = await AppDb.instance.db;
    // 三张核心表经 AppDb 读取方法；四张扩展表经原生行查询，
    // 统一再由现有 model 的 fromMap→toMap 清洗序列化。
    final quotes = (await db.getQuotes()).map((e) => e.toMap()).toList();
    final customers =
        (await db.getCustomers()).map((e) => e.toMap()).toList();
    final projects =
        (await db.getProjects()).map((e) => e.toMap()).toList();
    final payments = (await raw.query('payments'))
        .map((e) => Payment.fromMap(e).toMap())
        .toList();
    final pendingCollections = (await raw.query('pending_collections'))
        .map((e) => PendingCollection.fromMap(e).toMap())
        .toList();
    final milestones = (await raw.query('milestones'))
        .map((e) => Milestone.fromMap(e).toMap())
        .toList();
    final contracts = (await raw.query('contracts'))
        .map((e) => Contract.fromMap(e).toMap())
        .toList();

    final payload = <String, dynamic>{
      'exportVersion': kBackupVersion,
      'exportAt': DateTime.now().toIso8601String(),
      'data': <String, dynamic>{
        'quotes': quotes,
        'customers': customers,
        'projects': projects,
        'payments': payments,
        'pending_collections': pendingCollections,
        'milestones': milestones,
        'contracts': contracts,
      },
    };

    final fileName = '$kFileNamePrefix${_timestamp()}.json';
    final dir = await _pickTargetDir();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload));
    return file.path;
  }

  /// 选定备份文件存放目录：
  /// 优先写系统「下载」目录（桌面/部分平台 getDownloadsDirectory 可用）；
  /// Android 未实现该目录时回退到应用文档目录，再由 UI 层分享导出文件，
  /// 保证免存储权限、各 Android 版本均不闪退。
  Future<Directory> _pickTargetDir() async {
    try {
      final d = await getDownloadsDirectory();
      if (d != null) return d;
    } catch (_) {
      // Android 上 getDownloadsDirectory 不支持，走应用文档目录兜底。
    }
    final appDoc = await getApplicationDocumentsDirectory();
    final backups = Directory(p.join(appDoc.path, 'backups'));
    if (!backups.existsSync()) backups.createSync(recursive: true);
    return backups;
  }

  /// 从备份文件恢复全部业务数据（覆盖模式，事务保护）。
  ///
  /// [path] 备份 JSON 文件完整路径。
  /// 返回各表恢复条数 {customers, projects, quotes, payments,
  /// pending_collections, milestones, contracts}。
  /// 版本不兼容 / 结构不完整 / JSON 解析失败等均抛 [FormatException]（中文提示）。
  Future<Map<String, int>> restoreFromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('备份文件不存在');
    }
    // 解析 JSON（含解析层异常捕获，统一转中文提示）。
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (_) {
      throw const FormatException('备份文件不是有效的 JSON 文件');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件格式错误：顶层应为 JSON 对象');
    }
    // 1) 版本校验：不在支持范围内直接拒绝，避免错误覆盖。
    final version = decoded['exportVersion'];
    if (version is! String || !kSupportedVersions.contains(version)) {
      throw FormatException('备份文件版本不兼容（当前支持 v${kSupportedVersions.join('/')}）');
    }
    // 2) 字段完整性校验：data 段内三张核心业务表必须为数组；
    //    四张扩展表为 v1.1 新增，旧 v1.0 文件缺失时按空数据处理，不阻断导入。
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('备份文件缺少 data 数据段');
    }
    final quotes = _parseRows(data['quotes'], 'quotes');
    final customers = _parseRows(data['customers'], 'customers');
    final projects = _parseRows(data['projects'], 'projects');
    final payments = _parseOptionalRows(data['payments'], 'payments');
    final pendingCollections =
        _parseOptionalRows(data['pending_collections'], 'pending_collections');
    final milestones = _parseOptionalRows(data['milestones'], 'milestones');
    final contracts = _parseOptionalRows(data['contracts'], 'contracts');

    final db = await AppDb.instance.db;
    // 3) 事务覆盖恢复：先清空七张业务表再批量插入 → 提交；出错整体回滚。
    await db.transaction((txn) async {
      // 先按子表先删的顺序清空，再按父表先插的顺序写入，保证外键关联完整。
      // 删除顺序：子表 → 父表；插入顺序：父表（customers/projects）→ 子表。
      await txn.delete('quotes');
      await txn.delete('payments');
      await txn.delete('pending_collections');
      await txn.delete('milestones');
      await txn.delete('contracts');
      await txn.delete('projects');
      await txn.delete('customers');
      // 经现有 model 的 fromMap/toMap 清洗后插入，保留原 id 以维持
      // 客户-项目-报价/收款/待收/里程碑/合同 之间的关联关系；id 缺失时交给自增。
      for (final r in customers) {
        await txn.insert('customers', _withId(Customer.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in projects) {
        await txn.insert('projects', _withId(Project.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in quotes) {
        await txn.insert('quotes', _withId(Quote.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in payments) {
        await txn.insert('payments', _withId(Payment.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in pendingCollections) {
        await txn.insert(
            'pending_collections',
            _withId(PendingCollection.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in milestones) {
        await txn.insert('milestones', _withId(Milestone.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in contracts) {
        await txn.insert('contracts', _withId(Contract.fromMap(r).toMap()),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    return <String, int>{
      'customers': customers.length,
      'projects': projects.length,
      'quotes': quotes.length,
      'payments': payments.length,
      'pending_collections': pendingCollections.length,
      'milestones': milestones.length,
      'contracts': contracts.length,
    };
  }

  /// 校验 data 段内某核心表数组：必须为 List；逐行要求是 Map，非 Map 行丢弃。
  List<Map<String, Object?>> _parseRows(Object? rows, String table) {
    if (rows is! List) {
      throw FormatException('备份文件缺少「$table」数据，无法恢复');
    }
    return rows
        .whereType<Map>()
        .map((e) => e.cast<String, Object?>())
        .toList();
  }

  /// 校验 data 段内某扩展表数组：v1.1 新增的兼容表，旧版本文件缺失时
  /// 按空数据处理，不阻断导入（{table} 保留为空表即可）。
  List<Map<String, Object?>> _parseOptionalRows(Object? rows, String table) {
    if (rows == null) return const [];
    return _parseRows(rows, table);
  }

  /// 备份行若缺失 id（手工构造的文件），移除外键自增键，交给数据库自增。
  Map<String, Object?> _withId(Map<String, Object?> m) {
    if (m['id'] == null) m.remove('id');
    return m;
  }

  /// 生成 yyyyMMdd_HHmmss 时间戳（无中文，纯数字，兼容各平台文件名）。
  static String _timestamp() {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = DateTime.now();
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
