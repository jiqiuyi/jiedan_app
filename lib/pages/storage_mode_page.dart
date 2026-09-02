import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../api_client.dart';
import '../constants.dart';
import '../services/sync_service.dart';
import '../theme.dart';
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
                              '切回本地并删除服务器数据',
                              style: TextStyle(
                                color: isLoggedIn
                                    ? AppTheme.danger
                                    : AppTheme.textSub,
                              ),
                            ),
                            subtitle: Text(
                              isLoggedIn
                                  ? '清除本账号在服务器上的全部同步数据（仅影响本账号），删除前建议先到「数据管理」导出一份备份。'
                                  : '当前未登录，无法删除服务器数据',
                              style: const TextStyle(fontSize: 12),
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
                    ],
                  ),
                ),
              ],
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
