import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
      _toast('备份文件已生成，正在弹出分享');
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
      final summary = BackupService.instance.describeBackup(counts);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入成功'),
          content: Text(summary),
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
        ],
      ),
    );
  }
}
