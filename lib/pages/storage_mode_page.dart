import 'dart:async';
import '../l10n/l10n.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../api_client.dart';
import '../constants.dart';
import '../services/sync_service.dart';
import '../services/error_reporter.dart';
import '../theme.dart';
import '../utils/backup_util.dart';
import '../widgets/conflict_resolver_sheet.dart';
import 'login_page.dart';
import '../widgets/app_ui.dart';

/// 从含服务器模式切回「仅本地」时，用户在弹窗中的两档处理选择（+ 取消）。
enum LocalSwitchChoice { cancel, keepServer, deleteServer }

/// 数据存储方式选择页（v1.14.0，三选一，均不收费）。
///
/// 三种模式：
/// - 仅本地：业务数据只存手机，完全不访问云端业务接口（隐私承诺）；
/// - 仅服务器：以云端为权威，本地是缓存，任意设备登录均可读取；
/// - 本地 + 服务器：双写，本地修改后台推云端，登录/启动自动拉取合并，冲突以服务器最新为准。
/// v1.15.0：从含服务器模式切回仅本地时，弹两档确认（保留服务器数据 / 删除服务器数据，可删可不删，不默认删）。
class StorageModePage extends StatefulWidget {
const   StorageModePage({super.key});

  @override
  State<StorageModePage> createState() => _StorageModePageState();
}

class _StorageModePageState extends State<StorageModePage> {
  StorageMode? _selected;
  bool _syncing = false;
  String? _syncError;
  int? _lastSyncAt;

  /// 防止 token 失效跳登录在短时间内被重复触发（后台多路同步可能同时失败）。
  bool _authExpiredHandling = false;

  @override
  void initState() {
    super.initState();
    _selected = SyncService.instance.mode;
    SyncService.instance.addListener(_onSyncChanged);
    _syncError = SyncService.instance.lastError;
    _lastSyncAt = SyncService.instance.lastSyncAt;
  }

  @override
  void dispose() {
    SyncService.instance.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _onSyncChanged() {
    if (!mounted) return;
    setState(() {
      _syncing = SyncService.instance.syncing;
      _syncError = SyncService.instance.lastError;
      _lastSyncAt = SyncService.instance.lastSyncAt;
    });
    // token 失效独立分支：同步接口返回 401 时，清除会话并跳转登录。
    if (SyncService.instance.authExpired) {
      unawaited(_handleAuthExpired());
    }
  }

  /// token 失效统一处理：登出本地会话 → 提示 → 跳转登录页。
  Future<void> _handleAuthExpired([String? message]) async {
    if (_authExpiredHandling) return;
    _authExpiredHandling = true;
    try {
      // 清除本地会话（云端 token + 用户缓存），恢复未登录态。
      await AppState.instance.logout();
      SyncService.instance.clearAuthExpired();
    } finally {
      _authExpiredHandling = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message ?? L10n.instance.t('common_session_expired'))));
    // 独立分支：直接引导重新登录，而非停留在普通网络错误提示。
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LoginPage()),
    );
  }

  /// 从含服务器模式切回「仅本地」：两档处理弹窗。
  /// a) 仅切回本地、保留服务器数据（之后切回云端模式可再同步回来）；
  /// b) 切回本地并删除服务器上该账号的全部同步数据（调 DELETE /api/sync/all）。
  /// 「可删可不删」由用户在弹窗中二选一，不默认删除。
  ///
  /// 弹窗交互重写（软著改造）：由「底部一列按钮直接选择」改为
  /// 「选项列表 + 确认」两级交互——默认选中保留项，危险项置于列表尾部
  /// 并以警示色标注，未登录时删除项置灰不可选，降低误触删除风险。
  Future<void> _onSwitchToLocal(StorageMode target) async {
    final isLoggedIn = AppState.instance.loggedIn;
    // 默认保留服务器数据（不默认删除）。
    var keepServer = true;
    final choice = await showDialog<LocalSwitchChoice>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            return AlertDialog(
              title: Row(
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    color: AppTheme.warn,
                    size: 22,
                  ),
                  SizedBox(width: 8),
                  Expanded(child: Text(L10n.instance.t('storage_switch_local_confirm'))),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      L10n.instance.t('i18n_142') +
                      L10n.instance.t('i18n_435'),
                      style: TextStyle(height: 1.5),
                    ),
                    SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppTheme.divider),
                      ),
                      child: RadioGroup<LocalSwitchChoice>(
                        groupValue: keepServer
                            ? LocalSwitchChoice.keepServer
                            : LocalSwitchChoice.deleteServer,
                        onChanged: (v) {
                          if (v == null) return;
                          setDlgState(
                            () =>
                                keepServer = v == LocalSwitchChoice.keepServer,
                          );
                        },
                        child: Column(
                          children: [
                            // 选项一：保留服务器数据（默认选中，安全）。
                            RadioListTile<LocalSwitchChoice>(
                              value: LocalSwitchChoice.keepServer,
                              title: Text(L10n.instance.t('storage_switch_local_keep')),
                              subtitle: Text(
                                L10n.instance.t('i18n_088'),
                                style: TextStyle(fontSize: 12),
                              ),
                              secondary: const Icon(Icons.archive_outlined),
                            ),
                            const AppCardDivider(),
                            // 选项二：删除服务器数据（危险项，警示色，未登录置灰）。
                            RadioListTile<LocalSwitchChoice>(
                              value: LocalSwitchChoice.deleteServer,
                              enabled: isLoggedIn,
                              title: Text(
                                L10n.instance.t('i18n_145'),
                                style: TextStyle(
                                  color: isLoggedIn
                                      ? AppTheme.danger
                                      : AppTheme.textSub,
                                ),
                              ),
                              subtitle: Text(
                                isLoggedIn
                                    ? L10n.instance.t('i18n_141')
                                    : L10n.instance.t('i18n_309'),
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                              secondary: Icon(
                                Icons.delete_forever_outlined,
                                color: isLoggedIn
                                    ? AppTheme.danger
                                    : AppTheme.textSub,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, LocalSwitchChoice.cancel),
                  child: Text(L10n.instance.t('common_cancel')),
                ),
                AppButton(
                  label: keepServer ? L10n.instance.t('common_confirm_switch') : L10n.instance.t('storage_confirm_delete_switch'),
                  kind: keepServer
                      ? AppButtonKind.primary
                      : AppButtonKind.danger,
                  size: AppButtonSize.medium,
                  expand: false,
                  onPressed: () => Navigator.pop(
                    ctx,
                    keepServer
                        ? LocalSwitchChoice.keepServer
                        : LocalSwitchChoice.deleteServer,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (choice == null || choice == LocalSwitchChoice.cancel) return;

    final msg = await SyncService.instance.setMode(target);

    if (choice == LocalSwitchChoice.deleteServer) {
      try {
        final rows = await SyncService.instance.deleteServerData();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              rows > 0 ? L10n.instance.t('i18n_257', args: {'v0':'$rows'}) : L10n.instance.t('i18n_258'),
            ),
          ),
        );
      } on TokenInvalidException {
        // token 失效独立分支：删除服务器数据失败，引导重新登录。
        await _handleAuthExpired(L10n.instance.t('i18n_143'));
        setState(() => _selected = SyncService.instance.mode);
        return;
      } catch (e, st) {
        ErrorReporter.instance.logError(
          'sync_delete_server_failed',
          e,
          st,
          module: LogModule.sync,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L10n.instance.t('storage_switch_local_fail', args: {'e':'$e'}))));
      }
      setState(() => _selected = SyncService.instance.mode);
      return;
    }

    // keepServer
    setState(() => _selected = SyncService.instance.mode);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.instance.t('storage_server_data_kept', args: {'msg':msg}))));
    }
  }

  /// 选择后二次确认：模式差异 + 数据合并/导出提示（垂询要求）。
  Future<void> _onPick(StorageMode m) async {
    if (m == _selected) return;
    final cur = _selected ?? SyncService.instance.mode;
    // 从含服务器模式切回「仅本地」：走两档弹窗，可删可不删，不默认删。
    if (m == StorageMode.local && cur.involvesServer) {
      await _onSwitchToLocal(m);
      return;
    }
    final isLoggedIn = AppState.instance.loggedIn;
    if (m.involvesServer && !isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L10n.instance.t('storage_cloud_login'))));
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => LoginPage()),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final includesServer = m.involvesServer;
        return AlertDialog(
          title: Text(L10n.instance.t('storage_switch_mode', args: {'m.label': m.label})),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 摘要行：模式图标 + 一句话简介。
                Row(
                  children: [
                    Icon(_modeIcon(m), color: AppTheme.primary, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        m.summary,
                        style: TextStyle(fontSize: 14, height: 1.5),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                // 数据说明卡片。
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: AppTheme.divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.article_outlined,
                            size: 16,
                            color: AppTheme.textSub,
                          ),
                          SizedBox(width: 6),
                          Text(
                            L10n.instance.t('i18n_405'),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSub,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 6),
                      Text(
                        m.detail,
                        style: TextStyle(
                          color: AppTheme.textSub,
                          height: 1.6,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (includesServer) ...[
                  SizedBox(height: 10),
                  // 云端模式专属提示。
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warn.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                        color: AppTheme.warn.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_outlined,
                          size: 16,
                          color: AppTheme.warn,
                        ),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            L10n.instance.t('i18n_299') +
                            L10n.instance.t('i18n_139') +
                            L10n.instance.t('i18n_117'),
                            style: TextStyle(
                              color: AppTheme.textMain,
                              height: 1.6,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('common_confirm_switch')),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final String msg;
    try {
      msg = await SyncService.instance.setMode(m);
    } on TokenInvalidException {
      // token 失效独立分支：切换联动同步失败，引导重新登录。
      await _handleAuthExpired(L10n.instance.t('i18n_144'));
      if (mounted) setState(() => _selected = SyncService.instance.mode);
      return;
    }
    setState(() => _selected = SyncService.instance.mode);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // ---------- JSON 全量备份 / 恢复（BackupUtil，纯本地） ----------

  /// 备份/恢复进行中的可视反馈状态。
  bool _backupBusy = false;
  String _backupHint = '';

  /// 导出全部业务数据为 JSON 备份，生成后弹系统分享面板保存到下载/网盘/微信。
  Future<void> _onExportBackup() async {
    if (_backupBusy) return;
    setState(() {
      _backupBusy = true;
      _backupHint = L10n.instance.t('i18n_474');
    });
    try {
      final path = await BackupUtil.instance.exportAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.instance.t('storage_mode_page_backup_created', args: {'path':path})),
          duration: Duration(seconds: 3),
        ),
      );
      await Share.shareXFiles([
        XFile(path, mimeType: 'application/json'),
      ], text: L10n.instance.t('storage_backup_desc'));
    } catch (e, st) {
      ErrorReporter.instance.logError(
        'backup_export_failed',
        e,
        st,
        module: LogModule.db,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L10n.instance.t('storage_mode_page_backup_export', args: {'e':'$e'}))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
          _backupHint = '';
        });
      }
    }
  }

  /// 从 JSON 备份恢复数据（覆盖模式）。双层确认：
  /// 第一层：提示覆盖风险 + 建议先备份；第二层：选择文件后的最终确认。
  Future<void> _onRestoreBackup() async {
    // 第一层确认：覆盖警告 + 建议先备份。
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_outlined,
              color: AppTheme.danger,
              size: 22,
            ),
            SizedBox(width: 8),
            Expanded(child: Text(L10n.instance.t('storage_restore_confirm'))),
          ],
        ),
        content: Text(
          L10n.instance.t('i18n_325') +
          L10n.instance.t('i18n_319') +
          L10n.instance.t('i18n_085'),
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.instance.t('common_cancel')),
          ),
          AppButton(
            label: L10n.instance.t('storage_restore_choose'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;

    // 选择备份 JSON 文件（复用项目 file_picker 插件）。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: L10n.instance.t('i18n_612'),
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || !File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L10n.instance.t('storage_restore_unreadable'))));
      }
      return;
    }
    if (!mounted) return;

    // 第二层确认：最终执行前再次确认。
    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('storage_restore_overwrite')),
        content: Text(
          L10n.instance.t('i18n_243') +
          L10n.instance.t('i18n_318'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.instance.t('common_cancel')),
          ),
          AppButton(
            label: L10n.instance.t('storage_restore_confirm_btn'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (second != true || !mounted) return;

    setState(() {
      _backupBusy = true;
      _backupHint = L10n.instance.t('i18n_472');
    });
    try {
      final counts = await BackupUtil.instance.restoreFromFile(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L10n.instance.t('storage_restore_ok')),
          content: Text(
            L10n.instance.t('sm_restored_customers', args: {'v0':'${counts['customers'] ?? 0}'}) +
            L10n.instance.t('sm_restored_projects', args: {'v0':'${counts['projects'] ?? 0}'}) +
            L10n.instance.t('sm_restored_quotes', args: {'v0':'${counts['quotes'] ?? 0}'}) +
            L10n.instance.t('sm_restored_payments', args: {'v0':'${counts['payments'] ?? 0}'}) +
            L10n.instance.t('sm_restored_pending', args: {'v0':'${counts['pending_collections'] ?? 0}'}) +
            L10n.instance.t('sm_restored_milestones', args: {'v0':'${counts['milestones'] ?? 0}'}) +
            L10n.instance.t('sm_restored_contracts', args: {'v0':'${counts['contracts'] ?? 0}'}) +
            L10n.instance.t('i18n_456') +
            L10n.instance.t('i18n_548'),
            style: TextStyle(height: 1.6),
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
      _toast(L10n.instance.t('i18n_327', args: {'v0': e.message}));
    } catch (e, st) {
      ErrorReporter.instance.logError(
        'backup_import_failed',
        e,
        st,
        module: LogModule.db,
      );
      _toast(L10n.instance.t('i18n_326', args: {'v0':'$e'}));
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
          _backupHint = '';
        });
      }
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: Duration(seconds: 3)),
    );
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    try {
      await SyncService.instance.syncNow();
    } on TokenInvalidException {
      // token 失效独立分支：同步失败，引导重新登录。
      await _handleAuthExpired();
      if (mounted) setState(() {});
      return;
    }
    if (mounted) setState(() {});
  }

  String _syncStatusText() {
    if (_serverMode && !AppState.instance.loggedIn) {
      return L10n.instance.t('i18n_310');
    }
    if (_syncing) return L10n.instance.t('i18n_473');
    if (_syncError != null) return L10n.instance.t('i18n_070', args: {'v0':'$_syncError'});
    if (_lastSyncAt != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(_lastSyncAt!);
      return L10n.instance.t('sm_last_sync', args: {'v0': dt.hour.toString().padLeft(2, '0'), 'v1': dt.minute.toString().padLeft(2, '0')}) +
          L10n.instance.t('i18n_020', args: {'v0':'${dt.month}', 'v1':'${dt.day}'});
    }
    return L10n.instance.t('i18n_248');
  }

  bool get _serverMode =>
      (_selected ?? SyncService.instance.mode).involvesServer;

  /// 打开待处理同步冲突的解决弹层。
  void _showConflicts() => showConflictResolverSheet(context);

  /// 选择同步冲突处理策略：自动保留较新 / 有冲突时先问我。
  Future<void> _showConflictPolicyDialog() async {
    final sync = SyncService.instance;
    final cur = sync.conflictPolicy;
    final picked = await showAppSheet<SyncConflictPolicy>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: AppSheetHeader(title: L10n.instance.t('storage_conflict_policy')),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                L10n.instance.t('i18n_091'),
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
            for (final p in SyncConflictPolicy.values)
              ListTile(
                leading: Icon(
                  cur == p
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: cur == p ? AppTheme.primary : AppTheme.textSub,
                ),
                title: Text(p.label),
                subtitle: Text(
                  p.desc,
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == cur) return;
    sync.conflictPolicy = picked;
    _toast(L10n.instance.t('i18n_259', args: {'v0': picked.label}));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('storage_mode_title'))),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 备份/恢复进行中的进度反馈。
              if (_backupBusy)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _backupHint,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Text(
                L10n.instance.t('i18n_604') +
                L10n.instance.t('i18n_060'),
                style: TextStyle(
                  color: AppTheme.textSub,
                  height: 1.5,
                  fontSize: 13,
                ),
              ),
              SizedBox(height: 12),
              for (final m in StorageMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    margin: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      side: BorderSide(
                        color: _selected == m
                            ? AppTheme.primary
                            : AppTheme.divider,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      onTap: () => _onPick(m),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _modeIcon(m),
                                  color: _selected == m
                                      ? AppTheme.primary
                                      : AppTheme.textSub,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    m.label,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (m == StorageMode.local)
                                  Text(
                                    L10n.instance.t('i18n_629'),
                                    style: TextStyle(
                                      color: AppTheme.success,
                                      fontSize: 12,
                                    ),
                                  ),
                                Icon(
                                  _selected == m
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  color: AppTheme.primary,
                                  size: 22,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              m.summary,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSub,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              m.detail,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSub,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_serverMode) ...[
                SizedBox(height: 12),
                // 云端模式下的同步状态与「立即同步」操作区。
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          if (_syncing)
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(
                              _syncError != null
                                  ? Icons.error_outline
                                  : Icons.cloud_done_outlined,
                              color: _syncError != null
                                  ? AppTheme.danger
                                  : AppTheme.success,
                              size: 20,
                            ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _syncStatusText(),
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textMain,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _syncing ? null : _syncNow,
                          icon: Icon(Icons.sync, size: 18),
                          label: Text(L10n.instance.t('storage_sync_now')),
                        ),
                      ),
                      // 待处理冲突提示（askMe 策略收集到冲突时）。
                      if (SyncService.instance.hasPendingConflicts) ...[
                        SizedBox(height: 10),
                        Material(
                          color: AppTheme.danger.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            onTap: () => _showConflicts(),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    color: AppTheme.danger,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      L10n.instance.t('i18n_015', args: {'v0':'${SyncService.instance.pendingConflicts.length}'}),
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.danger,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: AppTheme.danger,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      // 同步冲突处理策略（v1.20.0）。
                      SizedBox(height: 10),
                      InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        onTap: _showConflictPolicyDialog,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.tune,
                                size: 16,
                                color: AppTheme.textSub,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                L10n.instance.t('i18n_169'),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSub,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  SyncService.instance.conflictPolicy.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.primary,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right,
                                size: 18,
                                color: AppTheme.textSub,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              SizedBox(height: 20),
              // ---- 本地数据备份 / 恢复（JSON 全量备份，纯本地操作）----
              Text(
                L10n.instance.t('i18n_396'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSub,
                ),
              ),
              SizedBox(height: 8),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: ListTile(
                  leading: Icon(
                    Icons.upload_file_outlined,
                    color: AppTheme.primary,
                  ),
                  title: Text(L10n.instance.t('storage_export_json')),
                  subtitle: Text(L10n.instance.t('storage_export_desc')),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: AppTheme.textSub,
                  ),
                  onTap: _onExportBackup,
                ),
              ),
              SizedBox(height: 8),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  side: BorderSide(
                    color: AppTheme.danger.withValues(alpha: 0.4),
                  ),
                ),
                child: ListTile(
                  leading: Icon(
                    Icons.settings_backup_restore,
                    color: AppTheme.danger,
                  ),
                  title: Text(
                    L10n.instance.t('i18n_108'),
                    style: TextStyle(color: AppTheme.danger),
                  ),
                  subtitle: Text(L10n.instance.t('storage_restore_overwrite_desc')),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppTheme.danger,
                  ),
                  onTap: _onRestoreBackup,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                L10n.instance.t('i18n_191'),
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          );
        },
      ),
    );
  }

  static IconData _modeIcon(StorageMode m) {
    switch (m) {
      case StorageMode.local:
        return Icons.phone_android;
      case StorageMode.server:
        return Icons.cloud_outlined;
      case StorageMode.both:
        return Icons.sync;
    }
  }
}
