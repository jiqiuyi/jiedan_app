import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../database.dart';

/// 数据备份服务：导出全部本地数据为 JSON 文件 / 从备份文件恢复。
/// 设计原则：业务数据只保存在手机本地，不上传服务器。
/// 卸载前请先导出备份，文件请自行保存到网盘/文件管理器/微信等安全位置。
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const _tables = [
    'customers',
    'projects',
    'payments',
    'users',
    'feedbacks',
    'invitees',
    'withdrawals',
    'recharges',
  ];

  /// 导出全部本地数据，生成 JSON 备份文件，返回文件路径。
  Future<String> exportBackup() async {
    final db = await AppDb.instance.db;
    final data = <String, dynamic>{};
    for (final t in _tables) {
      data[t] = await db.query(t);
    }
    final settingsRows = await db.query('settings');
    data['settings'] = {
      for (final r in settingsRows)
        r['key'] as String: r['value'],
    };

    final payload = {
      'app': 'jiedan_guanjia',
      'format': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'data': data,
    };

    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(dir.path, 'backups'));
    if (!backupDir.existsSync()) backupDir.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(backupDir.path, 'jiedan-backup-$stamp.json'));
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
    return file.path;
  }

  /// 分享备份文件（用户自行选择保存位置：网盘/文件管理器/微信等）。
  Future<void> shareBackup(String path) async {
    final result = await Share.shareXFiles(
      [XFile(path, mimeType: 'application/json')],
      text: '接单管家 数据备份文件，请妥善保存，重装后可导入恢复。',
    );
    if (result.status == ShareResultStatus.dismissed) {
      // 用户取消分享，文件仍在应用目录，不影响再次导出
    }
  }

  /// 解析并恢复备份文件。
  /// [path] 备份文件路径。
  /// 返回恢复的统计信息（各表条数）。
  /// 校验失败会抛出 [FormatException]。
  Future<Map<String, int>> importBackup(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('备份文件不存在');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic> || decoded['app'] != 'jiedan_guanjia') {
      throw FormatException('不是有效的接单管家备份文件');
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw FormatException('备份文件格式错误');
    }

    final db = await AppDb.instance.db;
    final counts = <String, int>{};
    await db.transaction((txn) async {
      for (final t in _tables) {
        await txn.delete(t);
      }
      await txn.delete('settings');

      for (final t in _tables) {
        final rows = data[t];
        if (rows is! List) continue;
        var n = 0;
        for (final r in rows) {
          if (r is! Map<String, dynamic>) continue;
          await txn.insert(t, r, conflictAlgorithm: ConflictAlgorithm.replace);
          n++;
        }
        counts[t] = n;
      }

      final settings = data['settings'];
      if (settings is Map<String, dynamic>) {
        for (final e in settings.entries) {
          await txn.insert(
            'settings',
            {'key': e.key, 'value': e.value?.toString() ?? ''},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        counts['settings'] = settings.length;
      }
    });
    return counts;
  }

  /// 生成备份文件的摘要信息，用于展示。
  String describeBackup(Map<String, int> counts) {
    final sb = StringBuffer('恢复完成：\n');
    const names = {
      'customers': '客户',
      'projects': '项目',
      'payments': '收款记录',
      'users': '账号',
      'feedbacks': '反馈',
      'invitees': '邀请记录',
      'withdrawals': '提现记录',
      'recharges': '充值记录',
      'settings': '设置项',
    };
    for (final e in counts.entries) {
      sb.writeln('${names[e.key] ?? e.key}：${e.value} 条');
    }
    return sb.toString();
  }
}
