import 'dart:io';
import '../l10n/l10n.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../database.dart';
import '../services/backup_service.dart';
import '../services/error_reporter.dart';
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
      SnackBar(content: Text(msg), duration: Duration(seconds: 3)),
    );
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await BackupService.instance.exportBackup();
      _toast(L10n.instance.t('i18n_194', args: {'v0': path}));
      await BackupService.instance.shareBackup(path);
    } catch (e, st) {
      ErrorReporter.instance.logError(
        'backup_export_failed',
        e,
        st,
        module: LogModule.db,
      );
      _toast(L10n.instance.t('i18n_242', args: {'v0':'$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: L10n.instance.t('i18n_612'),
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || !File(path).existsSync()) {
      _toast(L10n.instance.t('i18n_413'));
      return;
    }
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('data_import_confirm')),
        content: Text(
          L10n.instance.t('i18n_239') +
          L10n.instance.t('i18n_293'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.instance.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('data_import_btn')),
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
          title: Text(L10n.instance.t('data_import_ok')),
          content: Text(
            L10n.instance.t('i18n_011', args: {'v0': summary}) +
            L10n.instance.t('i18n_040'),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(L10n.instance.t('common_ok')),
            ),
          ],
        ),
      );
    } on FormatException catch (e) {
      _toast(L10n.instance.t('i18n_241', args: {'v0': e.message}));
    } catch (e, st) {
      ErrorReporter.instance.logError(
        'backup_import_failed',
        e,
        st,
        module: LogModule.db,
      );
      _toast(L10n.instance.t('i18n_240', args: {'v0':'$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('data_management_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- 隐私声明 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: AppTheme.primary),
                      SizedBox(width: 8),
                      Text(
                        L10n.instance.t('i18n_398'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Text(
                    L10n.instance.t('i18n_458'),
                    style: TextStyle(height: 1.5),
                  ),
                  SizedBox(height: 8),
                  Text(
                    L10n.instance.t('i18n_086'),
                    style: TextStyle(height: 1.5, color: AppTheme.textSub),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 16),
          // ---- 导出 ----
          Card(
            child: ListTile(
              leading: Icon(
                Icons.upload_file_outlined,
                color: AppTheme.primary,
              ),
              title: Text(L10n.instance.t('storage_export')),
              subtitle: Text(L10n.instance.t('data_export_desc')),
              trailing: _busy
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: _export,
            ),
          ),
          SizedBox(height: 12),
          // ---- 导入 ----
          Card(
            child: ListTile(
              leading: Icon(
                Icons.download_outlined,
                color: AppTheme.primary,
              ),
              title: Text(L10n.instance.t('storage_import')),
              subtitle: Text(L10n.instance.t('data_import_desc')),
              trailing: Icon(
                Icons.chevron_right,
                color: AppTheme.textSub,
              ),
              onTap: _import,
            ),
          ),
          SizedBox(height: 12),
          // ---- 数据库自检（v1.23.0）----
          Card(
            child: ListTile(
              leading: Icon(
                Icons.health_and_safety_outlined,
                color: AppTheme.primary,
              ),
              title: Text(L10n.instance.t('storage_db_check')),
              subtitle: Text(L10n.instance.t('data_dbcheck_desc')),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppTheme.textSub,
              ),
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
          title: Text(report.healthy ? L10n.instance.t('data_dbcheck_ok') : L10n.instance.t('data_dbcheck_fail')),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _row(L10n.instance.t('i18n_467'), _fmtTime(report.checkedAt)),
                _row(
                  L10n.instance.t('i18n_407'),
                  report.integrityCheck == 'ok'
                      ? L10n.instance.t('i18n_477')
                      : L10n.instance.t('i18n_305', args: {'v0': report.integrityCheck}),
                ),
                _row(
                  L10n.instance.t('i18n_203'),
                  report.foreignKeyIssues.isEmpty
                      ? L10n.instance.t('i18n_477')
                      : L10n.instance.t('i18n_157', args: {'v0':'${report.foreignKeyIssues.length}'}),
                ),
                _row(
                  L10n.instance.t('i18n_553'),
                  report.tables.isEmpty
                      ? L10n.instance.t('i18n_127')
                      : L10n.instance.t('i18n_024', args: {'v0':'${report.tables.length}'}),
                ),
                _row(L10n.instance.t('i18n_406'), L10n.instance.t('i18n_130', args: {'v0':'${report.totalRows}'})),
                if (report.tables.isNotEmpty)
                  for (final t in report.tables)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '• ${t.table}：${t.describe}',
                        style: const TextStyle(color: AppTheme.danger),
                      ),
                    ),
                const SizedBox(height: 12),
                Text(
                  report.healthy
                      ? L10n.instance.t('i18n_399')
                      : L10n.instance.t('i18n_469'),
                  style: const TextStyle(
                    color: AppTheme.textSub,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(L10n.instance.t('common_ok')),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast(L10n.instance.t('i18n_546', args: {'v0':'$e'}));
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
            child: Text(
              key,
              style: const TextStyle(color: AppTheme.textSub, fontSize: 14),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }
}
