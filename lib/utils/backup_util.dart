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
/// 【备份范围】仅备份业务用户数据，共三张业务表：
///   - quotes（报价单）
///   - customers（客户）
///   - projects（项目）
/// 以上全部记录通过现有 model 的 toMap() 序列化为 JSON 数组；
/// 不导出云端同步状态标记、token、登录会话及应用运行时状态。
///
/// 【备份文件结构】
/// {
///   "exportVersion": "1.0",          // 格式版本，用于将来兼容判断
///   "exportAt": "2026-09-02T...",    // 导出时间戳
///   "data": {
///     "quotes": [...], "customers": [...], "projects": [...]
///   }
/// }
///
/// 【恢复策略（高风险，覆盖模式）】
/// 开启数据库事务 → 清空 quotes/customers/projects 三张业务表 → 批量插入
/// 备份内全部记录 → 事务提交；任意一步出错整体回滚，绝不残留半份导入数据。
/// 恢复只操作本地业务数据，不触碰云端同步逻辑，不会自动上传/删除服务器数据。
/// 如用户开启了云端同步，恢复完成后需手动触发一次同步。
///
/// 【风险提示】恢复会覆盖当前手机上的全部报价/客户/项目数据且不可撤销，
/// 调用方（UI 层）必须提供双层确认后再调用 [restoreFromFile]。
/// ====================================================================
class BackupUtil {
  BackupUtil._();
  static final BackupUtil instance = BackupUtil._();

  /// 备份格式版本。将来若调整 JSON 结构（新增表/字段）需递增该版本号，
  /// 恢复时版本不匹配直接拒绝导入，防止旧文件错误覆盖新数据。
  static const String kBackupVersion = '1.0';

  /// 导出文件名前缀。
  static const String kFileNamePrefix = '接单管家_备份_';

  /// 一次导出三张业务表全部数据，生成 JSON 全量备份，返回文件完整路径。
  /// 导出成功后再由 UI 层通过系统分享面板让用户保存到下载/网盘/微信。
  Future<String> exportAll() async {
    final db = AppDb.instance;
    // 一次性读取三张业务表全部记录，经 model 序列化为 Map。
    final quotes = (await db.getQuotes()).map((e) => e.toMap()).toList();
    final customers =
        (await db.getCustomers()).map((e) => e.toMap()).toList();
    final projects =
        (await db.getProjects()).map((e) => e.toMap()).toList();

    final payload = <String, dynamic>{
      'exportVersion': kBackupVersion,
      'exportAt': DateTime.now().toIso8601String(),
      'data': <String, dynamic>{
        'quotes': quotes,
        'customers': customers,
        'projects': projects,
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
  /// 返回各表恢复条数 {customers, projects, quotes}。
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
    // 1) 版本校验：exportVersion 不匹配直接拒绝，避免错误覆盖。
    final version = decoded['exportVersion'];
    if (version != kBackupVersion) {
      throw FormatException('备份文件版本不兼容（当前支持 v$kBackupVersion）');
    }
    // 2) 字段完整性校验：必须在 data 段内提供三张业务表数组。
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('备份文件缺少 data 数据段');
    }
    final quotes = _parseRows(data['quotes'], 'quotes');
    final customers = _parseRows(data['customers'], 'customers');
    final projects = _parseRows(data['projects'], 'projects');

    final db = await AppDb.instance.db;
    // 3) 事务覆盖恢复：清空三表 → 批量插入 → 提交；出错整体回滚。
    await db.transaction((txn) async {
      // 先清子表再清父表，避免残留引用关系。
      await txn.delete('quotes');
      await txn.delete('projects');
      await txn.delete('customers');
      // 经现有 model 的 fromMap/toMap 清洗后插入，保留原 id 以维持
      // 客户-项目-报价 之间的关联关系；id 缺失时交给自增。
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
    });
    return <String, int>{
      'customers': customers.length,
      'projects': projects.length,
      'quotes': quotes.length,
    };
  }

  /// 校验 data 段内某表数组：必须为 List；逐行要求是 Map，非 Map 行丢弃。
  List<Map<String, Object?>> _parseRows(Object? rows, String table) {
    if (rows is! List) {
      throw FormatException('备份文件缺少「$table」数据，无法恢复');
    }
    return rows
        .whereType<Map>()
        .map((e) => e.cast<String, Object?>())
        .toList();
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
