import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../api_client.dart';
import '../constants.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../utils/backup_util.dart';
import '../widgets/conflict_resolver_sheet.dart';
import 'login_page.dart';

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
  const StorageModePage({super.key});

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message ?? '登录已失效，请重新登录'),
    ));
    // 独立分支：直接引导重新登录，而非停留在普通网络错误提示。
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
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
        return StatefulBuilder(builder: (ctx, setDlgState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.cloud_off_outlined,
                    color: AppTheme.warn, size: 22),
                SizedBox(width: 8),
                Expanded(child: Text('切换到「仅本地」？')),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '切换后手机端将不再访问云端业务接口，本地数据保持不变。'
                    '服务器上此前已同步的数据该如何处理？',
                    style: TextStyle(height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: AppTheme.bgCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.divider),
                    ),
                    child: RadioGroup<LocalSwitchChoice>(
                      groupValue: keepServer
                          ? LocalSwitchChoice.keepServer
                          : LocalSwitchChoice.deleteServer,
                      onChanged: (v) {
                        if (v == null) return;
                        setDlgState(
                            () => keepServer = v == LocalSwitchChoice.keepServer);
                      },
                      child: Column(
                        children: [
                          // 选项一：保留服务器数据（默认选中，安全）。
                          RadioListTile<LocalSwitchChoice>(
                            value: LocalSwitchChoice.keepServer,
                            title: const Text('仅切回本地，保留服务器数据'),
                            subtitle: const Text(
                              '之后切回云端模式时可再同步回来，数据更安全。',
                              style: TextStyle(fontSize: 12),
                            ),
                            secondary: const Icon(Icons.archive_outlined),
                          ),
                          const Divider(height: 1),
                          // 选项二：删除服务器数据（危险项，警示色，未登录置灰）。
                          RadioListTile<LocalSwitchChoice>(
                            value: LocalSwitchChoice.deleteServer,
                            enabled: isLoggedIn,
                            title: Text(
                              '删除服务器数据',
                              style: TextStyle(
                                color: isLoggedIn
                                    ? AppTheme.danger
                                    : AppTheme.textSub,
                              ),
                            ),
                            subtitle: Text(
                              isLoggedIn
                                  ? '切回本地，并清除本账号在服务器上的全部同步数据（仅影响本账号），删除前建议先到「数据管理」导出一份备份。'
                                  : '当前未登录，无法删除服务器数据',
                              style: const TextStyle(
                                  fontSize: 12, height: 1.5),
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
                child: const Text('取消'),
              ),
              FilledButton(
                style: keepServer
                    ? null
                    : FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                onPressed: () => Navigator.pop(
                  ctx,
                  keepServer
                      ? LocalSwitchChoice.keepServer
                      : LocalSwitchChoice.deleteServer,
                ),
                child: Text(keepServer ? '确认切换' : '确认删除并切换'),
              ),
            ],
          );
        });
      },
    );
    if (choice == null || choice == LocalSwitchChoice.cancel) return;

    final msg = await SyncService.instance.setMode(target);

    if (choice == LocalSwitchChoice.deleteServer) {
      try {
        final rows = await SyncService.instance.deleteServerData();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            rows > 0
                ? '已切换仅本地，并删除服务器上的 $rows 条同步数据。'
                : '已切换仅本地，并清除服务器同步数据。',
          ),
        ));
      } on TokenInvalidException {
        // token 失效独立分支：删除服务器数据失败，引导重新登录。
        await _handleAuthExpired('切换已完成，但删除服务器数据需重新登录：请重新登录后再操作');
        setState(() => _selected = SyncService.instance.mode);
        return;
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已切换仅本地，但删除服务器数据失败：$e'),
        ));
      }
      setState(() => _selected = SyncService.instance.mode);
      return;
    }

    // keepServer
    setState(() => _selected = SyncService.instance.mode);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$msg 服务器数据已保留，之后切回云端模式可再同步回来。'),
      ));
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('云端存储需要先登录账号')),
      );
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final includesServer = m.involvesServer;
        return AlertDialog(
          title: Text('切换到「${m.label}」？'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 摘要行：模式图标 + 一句话简介。
                Row(
                  children: [
                    Icon(_modeIcon(m), color: AppTheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        m.summary,
                        style: const TextStyle(fontSize: 14, height: 1.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 数据说明卡片。
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.article_outlined,
                              size: 16, color: AppTheme.textSub),
                          SizedBox(width: 6),
                          Text('数据说明',
                              style: TextStyle(
                                  fontSize: 12, color: AppTheme.textSub)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        m.detail,
                        style: const TextStyle(
                            color: AppTheme.textSub, height: 1.6, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (includesServer) ...[
                  const SizedBox(height: 10),
                  // 云端模式专属提示。
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warn.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: AppTheme.warn.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_outlined,
                            size: 16, color: AppTheme.warn),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '开启云端后，本地存量数据会一次性全量上传并与云端合并，'
                            '冲突以服务器最新为准。建议先到「数据管理」导出一份备份，'
                            '保管好自己的账号密码。',
                            style: TextStyle(
                                color: AppTheme.textMain,
                                height: 1.6,
                                fontSize: 13),
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
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认切换'),
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
      await _handleAuthExpired('切换未完成：登录已失效，请重新登录');
      if (mounted) setState(() => _selected = SyncService.instance.mode);
      return;
    }
    setState(() => _selected = SyncService.instance.mode);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
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
      _backupHint = '正在导出备份数据…';
    });
    try {
      final path = await BackupUtil.instance.exportAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('备份文件已生成：$path'),
        duration: const Duration(seconds: 3),
      ));
      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/json')],
        text: '接单管家 数据备份文件，请妥善保存，重装后可导入恢复。',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出备份失败：$e')),
        );
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
        title: const Row(
          children: [
            Icon(Icons.warning_amber_outlined, color: AppTheme.danger, size: 22),
            SizedBox(width: 8),
            Expanded(child: Text('从备份恢复数据？')),
          ],
        ),
        content: const Text(
          '恢复会用备份文件覆盖本地现有的报价单、客户、项目、收款记录、'
          '待收款、里程碑、合同等全部数据，覆盖后不可撤销。\n\n'
          '为避免误操作丢失数据，建议先执行一次「导出全部备份JSON」。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续，选择备份文件'),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;

    // 选择备份 JSON 文件（复用项目 file_picker 插件）。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: '选择接单管家备份文件',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || !File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法读取所选备份文件')),
        );
      }
      return;
    }
    if (!mounted) return;

    // 第二层确认：最终执行前再次确认。
    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认覆盖恢复？'),
        content: const Text('将清空本地现有的报价单、客户、项目、收款记录、'
            '待收款、里程碑、合同等全部数据，并替换为所选备份文件内容。确认继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (second != true || !mounted) return;

    setState(() {
      _backupBusy = true;
      _backupHint = '正在从备份恢复数据，请稍候…';
    });
    try {
      final counts = await BackupUtil.instance.restoreFromFile(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复成功'),
          content: Text(
            '已恢复：客户 ${counts['customers'] ?? 0} 条、'
            '项目 ${counts['projects'] ?? 0} 条、'
            '报价 ${counts['quotes'] ?? 0} 条、'
            '收款 ${counts['payments'] ?? 0} 条、'
            '待收 ${counts['pending_collections'] ?? 0} 条、'
            '里程碑 ${counts['milestones'] ?? 0} 条、'
            '合同 ${counts['contracts'] ?? 0} 条。\n\n'
            '本次恢复仅写入本地数据，不会自动上传或删除服务器数据。'
            '若您开启了云端同步，请手动触发一次「立即同步」。',
            style: const TextStyle(height: 1.6),
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
      _toast('恢复失败：${e.message}');
    } catch (e) {
      _toast('恢复失败：$e');
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
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    try {
      await SyncService.instance.pushNow();
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
      return '当前未登录，登录后即可同步云端数据';
    }
    if (_syncing) return '正在同步…';
    if (_syncError != null) return '上次同步失败：$_syncError（可点击“立即同步”重试）';
    if (_lastSyncAt != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(_lastSyncAt!);
      return '上次同步：${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} '
          '${dt.month}月${dt.day}日';
    }
    return '尚未开始同步';
  }

  bool get _serverMode => (_selected ?? SyncService.instance.mode).involvesServer;

  /// 打开待处理同步冲突的解决弹层。
  void _showConflicts() => showConflictResolverSheet(context);

  /// 选择同步冲突处理策略：自动保留较新 / 有冲突时先问我。
  Future<void> _showConflictPolicyDialog() async {
    final sync = SyncService.instance;
    final cur = sync.conflictPolicy;
    final picked = await showModalBottomSheet<SyncConflictPolicy>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                '同步冲突处理策略',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '云端与本地对同一条数据都有了修改时该怎么处理：',
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
                subtitle: Text(p.desc,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSub)),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == cur) return;
    sync.conflictPolicy = picked;
    _toast('已切换冲突处理策略：${picked.label}');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据存储方式')),
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
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
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
              const Text(
                '选择业务数据的存放位置：仅本地 / 仅服务器 / 本地+服务器，'
                '三种模式均不收费，可随时切换。',
                style: TextStyle(
                    color: AppTheme.textSub, height: 1.5, fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final m in StorageMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    margin: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: _selected == m
                            ? AppTheme.primary
                            : AppTheme.divider,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
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
                                        fontWeight: FontWeight.w700),
                                  ),
                                ),
                                if (m == StorageMode.local)
                                  const Text(
                                    '隐私优先',
                                    style: TextStyle(
                                        color: AppTheme.success, fontSize: 12),
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
                                  fontSize: 13, color: AppTheme.textSub),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              m.detail,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSub,
                                  height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_serverMode) ...[
                const SizedBox(height: 12),
                // 云端模式下的同步状态与「立即同步」操作区。
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          if (_syncing)
                            const SizedBox(
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
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _syncStatusText(),
                              style: const TextStyle(
                                  fontSize: 13, color: AppTheme.textMain),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _syncing ? null : _syncNow,
                          icon: const Icon(Icons.sync, size: 18),
                          label: const Text('立即同步'),
                        ),
                      ),
                      // 待处理冲突提示（askMe 策略收集到冲突时）。
                      if (SyncService.instance.hasPendingConflicts) ...[
                        const SizedBox(height: 10),
                        Material(
                          color: AppTheme.danger.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _showConflicts(),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber_rounded,
                                      color: AppTheme.danger, size: 20),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      '${SyncService.instance.pendingConflicts.length} 条数据存在同步冲突，需要您决定采用哪一版',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.danger,
                                          height: 1.4),
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right,
                                      color: AppTheme.danger, size: 20),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      // 同步冲突处理策略（v1.20.0）。
                      const SizedBox(height: 10),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: _showConflictPolicyDialog,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 6),
                          child: Row(
                            children: [
                              const Icon(Icons.tune, size: 16,
                                  color: AppTheme.textSub),
                              const SizedBox(width: 8),
                              const Text('同步冲突处理：',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textSub)),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  SyncService
                                      .instance.conflictPolicy.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.primary),
                                ),
                              ),
                              const Icon(Icons.chevron_right,
                                  size: 18, color: AppTheme.textSub),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              // ---- 本地数据备份 / 恢复（JSON 全量备份，纯本地操作）----
              const Text(
                '数据备份',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSub),
              ),
              const SizedBox(height: 8),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  leading: const Icon(Icons.upload_file_outlined,
                      color: AppTheme.primary),
                  title: const Text('导出全部备份JSON'),
                  subtitle: const Text('将报价、客户、项目、收款等全部数据导出为备份文件保存'),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppTheme.textSub),
                  onTap: _onExportBackup,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: AppTheme.danger.withValues(alpha: 0.4)),
                ),
                child: ListTile(
                  leading: const Icon(Icons.settings_backup_restore,
                      color: AppTheme.danger),
                  title: Text(
                    '从JSON备份恢复数据',
                    style: TextStyle(color: AppTheme.danger),
                  ),
                  subtitle: const Text('用备份文件覆盖恢复（会覆盖现有数据，请谨慎操作）'),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppTheme.danger),
                  onTap: _onRestoreBackup,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '备份恢复仅在本机进行，不会自动上传或删除服务器数据。',
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
