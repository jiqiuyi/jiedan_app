import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../database.dart';
import '../services/backup_service.dart';
import '../theme.dart';

/// 数据管理页：导出备份 / 导入恢复。
/// 设计原则：业务数据只保存在手机本地，不上传服务器。
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  bool _busy = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await BackupService.instance.exportBackup();
      _toast('备份文件已生成（$path），正在弹出分享');
      await BackupService.instance.shareBackup(path);
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: '选择接单管家备份文件',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || !File(path).existsSync()) {
      _toast('无法读取所选文件');
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入恢复？'),
        content: const Text('导入会清空当前手机上的客户、项目、收款等全部数据，'
            '并用备份文件内容覆盖。建议先导出当前数据再导入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final counts = await BackupService.instance.importBackup(path);
      // 防破解加固（P2）：备份可能被篡改（伪造 is_pro=1），导入后强制清除
      // 云端 token 与本地会话，要求用户重新登录，VIP 以云端 me() 为准覆盖。
      await ApiClient.instance.clearToken();
      await AppState.instance.clearSession();
      final summary = BackupService.instance.describeBackup(counts);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入成功'),
          content: Text(
            '$summary\n\n安全提示：为保护账号权益，导入后已退出登录，'
            'VIP 状态将以云端账号为准，请重新登录。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('好的'),
            ),
          ],
        ),
      );
    } on FormatException catch (e) {
      _toast('导入失败：${e.message}');
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- 隐私声明 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: AppTheme.primary),
                      SizedBox(width: 8),
                      Text(
                        '数据安全说明',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text(
                    '本软件不会将数据保存在服务器，所有项目、客户、收款等数据都只保存在您自己的手机里。',
                    style: TextStyle(height: 1.5),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '为防止卸载软件清空数据，请在卸载前先导出备份，并将备份文件保存到网盘、文件管理器或微信等安全位置，重装后可导入恢复。',
                    style: TextStyle(height: 1.5, color: AppTheme.textSub),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // ---- 导出 ----
          Card(
            child: ListTile(
              leading: const Icon(Icons.upload_file_outlined,
                  color: AppTheme.primary),
              title: const Text('导出备份'),
              subtitle: const Text('将全部数据打包成文件，可分享保存到网盘/微信'),
              trailing: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: _export,
            ),
          ),
          const SizedBox(height: 12),
          // ---- 导入 ----
          Card(
            child: ListTile(
              leading: const Icon(Icons.download_outlined,
                  color: AppTheme.primary),
              title: const Text('导入恢复'),
              subtitle: const Text('从备份文件恢复数据（会覆盖当前数据）'),
              trailing: const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: _import,
            ),
          ),
          const SizedBox(height: 12),
          // ---- 数据库自检（v1.23.0）----
          Card(
            child: ListTile(
              leading: const Icon(Icons.health_and_safety_outlined,
                  color: AppTheme.primary),
              title: const Text('数据库自检'),
              subtitle: const Text('检查表结构完整性与数据可恢复性'),
              trailing: const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: _healthCheck,
            ),
          ),
        ],
      ),
    );
  }

  // 数据库自检（v1.23.0）：只读检查表结构完整性 / 库文件完整性 / 外键引用，
  // 并给出数据可恢复性提示，全程不修改任何数据。
  Future<void> _healthCheck() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final report = await AppDb.instance.healthCheck();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(report.healthy ? '数据库自检通过' : '数据库自检发现异常'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _row('检查时间', _fmtTime(report.checkedAt)),
                _row('文件完整性',
                    report.integrityCheck == 'ok' ? '正常' : '异常：${report.integrityCheck}'),
                _row('外键引用校验',
                    report.foreignKeyIssues.isEmpty
                        ? '正常'
                        : '发现 ${report.foreignKeyIssues.length} 处问题'),
                _row('表结构完整性', report.tables.isEmpty
                    ? '全部完整'
                    : '${report.tables.length} 张表异常'),
                _row('数据量', '共 ${report.totalRows} 条记录'),
                if (report.tables.isNotEmpty)
                  for (final t in report.tables)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('• ${t.table}：${t.describe}',
                          style: const TextStyle(color: AppTheme.danger)),
                    ),
                const SizedBox(height: 12),
                Text(
                  report.healthy
                      ? '数据完整可正常使用。为防手机丢失 / 卸载清空，建议定期到「导出备份」将数据另存到网盘或微信。'
                      : '检测到异常，当前不影响继续使用；为稳妥建议先「导出备份」，必要时可在本页做一次恢复演练，并联系开发者排查。',
                  style: const TextStyle(
                      color: AppTheme.textSub, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast('自检失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(key,
                style: const TextStyle(color: AppTheme.textSub, fontSize: 14)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }
}
