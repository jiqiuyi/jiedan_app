import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../constants.dart';
import '../database.dart';
import 'error_reporter.dart';

/// 同步冲突处理策略（v1.20.0）。
enum SyncConflictPolicy {
  autoNewest(
    '自动保留较新的数据',
    '同步时自动以「更新时间较新」的一方为准，无需手动处理',
  ),
  askMe(
    '有冲突时先问我',
    '云端与本地对同一条数据都有修改时，先停下来由您选择采用哪一方',
  );

  const SyncConflictPolicy(this.label, this.desc);
  final String label;
  final String desc;
}

/// 一条待用户决策的同步冲突（云端更新将与本地不同版本冲突）。
class SyncConflict {
  const SyncConflict({
    required this.table,
    required this.id,
    required this.title,
    required this.localTs,
    required this.serverTs,
    required this.serverRow,
  });

  final String table;
  final int id;

  /// 面向用户展示的条目名称（客户名 / 项目名 / 报价标题等）。
  final String title;

  /// 本地更新时间（毫秒）。
  final int localTs;

  /// 服务器更新时间（毫秒）。
  final int serverTs;

  /// 服务器侧待采用的行数据（采用云端时直接落地）。
  final Map<String, Object?> serverRow;

  String get key => '$table:$id';
}

/// 云端业务数据同步服务（v1.14.0，存储方式三选一）。
///
/// 职责：
/// - 依据当前 [StorageMode] 决定是否访问云端业务接口：
///   * 仅本地：从不访问云端业务接口（隐私承诺），本地写入不触发任何同步；
///   * 仅服务器 / 本地+服务器：本地每次写入后后台异步推云端，登录/启动时拉取合并。
/// - 同步范围：customers / projects / payments / quotes / pending_collections /
///   milestones / contracts（客户/项目/收款/报价等核心表 + 关联表）。
/// - 增量：每行携带 `_ts`（毫秒，取业务时间与 updated_at 的较大者）与删除墓碑
///   `_deleted`；服务器按 `_ts` 合并，冲突以服务器最新为准（server-wins）。
/// - 隔离：后端按登录用户 uid 命名空间存储，用户间互不可见。
class SyncService extends ChangeNotifier {
  SyncService._() {
    // 挂接数据变更回调：本地每次写入后按需触发后台同步。
    AppDb.onDataChanged = onLocalChanged;
  }

  static final SyncService instance = SyncService._();

  /// 同步表定义（与后端契约一致）。
  static const List<String> tables = [
    'customers',
    'projects',
    'payments',
    'quotes',
    'pending_collections',
    'milestones',
    'contracts',
  ];

  StorageMode _mode = StorageMode.local;
  StorageMode get mode => _mode;

  bool _syncing = false;
  bool get syncing => _syncing;

  String? _lastError;
  String? get lastError => _lastError;

  int? _lastSyncAt;
  int? get lastSyncAt => _lastSyncAt;

  /// 云端鉴权是否已失效（同步接口返回 401，token 失效 / 未授权）。
  /// 页面据此提示并引导用户重新登录。
  bool _authExpired = false;
  bool get authExpired => _authExpired;

  /// 冲突处理策略（v1.20.0）：autoNewest 自动保留较新；askMe 收集冲突由用户决策。
  SyncConflictPolicy _policy = SyncConflictPolicy.autoNewest;
  SyncConflictPolicy get conflictPolicy => _policy;
  set conflictPolicy(SyncConflictPolicy v) {
    if (_policy == v) return;
    _policy = v;
    AppDb.instance
        .setSetting(
          AppConfig.syncConflictPolicyKey,
          v == SyncConflictPolicy.askMe ? 'ask_me' : 'auto_newest',
        );
    notifyListeners();
    // 切回「自动保留较新」后，把仍在等待的冲突按较新策略自动收尾。
    if (v == SyncConflictPolicy.autoNewest && _pending.isNotEmpty) {
      unawaited(_runMutex(() async {
        for (final c in List.of(_pending)) {
          await _resolveAuto(c);
        }
      }));
    }
  }

  /// 待用户决策的冲突列表（askMe 策略下收集）。
  final List<SyncConflict> _pending = [];
  List<SyncConflict> get pendingConflicts => List.unmodifiable(_pending);
  bool get hasPendingConflicts => _pending.isNotEmpty;

  /// 用户「保留本地」的忽略集缓存：键 <表名>:<云端id> -> 当时的服务器时间戳。
  final Map<String, int> _keepLocalCache = {};
  bool _keepLocalLoaded = false;

  /// 清除鉴权失效标记（页面完成登出 / 跳转登录后调用，避免重复触发）。
  void clearAuthExpired() {
    if (!_authExpired) return;
    _authExpired = false;
    notifyListeners();
  }

  bool _inited = false;

  // keep-alive 服务本身不被 UI 重建，用 _syncing 作为并发锁。
  Timer? _pushTimer;

  /// 应用启动时调用：读取持久化存储方式并立即执行一次首次合并（仅含服务器模式）。
  /// 必须在 AppDb 可用后调用。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final raw = await AppDb.instance.getSetting(AppConfig.storageModeKey);
    switch (raw) {
      case 'server':
        _mode = StorageMode.server;
        break;
      case 'both':
        _mode = StorageMode.both;
        break;
      default:
        _mode = StorageMode.local;
    }
    // 读取冲突处理策略（默认自动保留较新）。
    final policy =
        await AppDb.instance.getSetting(AppConfig.syncConflictPolicyKey);
    _policy = policy == 'ask_me'
        ? SyncConflictPolicy.askMe
        : SyncConflictPolicy.autoNewest;
    notifyListeners();
    // 仅本地模式：绝不访问云端业务接口。
    if (_mode.involvesServer) {
      unawaited(_runMutex(() => syncOnStart()));
    }
  }

  /// 当前是否具备同步条件（模式含服务器 + 已登录拿到 token）。
  bool get canSync => _mode.involvesServer && ApiClient.instance.token != null;

  /// 切换存储方式。[silent] 为 true 时不触发首次全量合并（用于 UI 仅展示）。
  /// 返回切换结果描述供页面提示（首次切到含服务器模式会做一次性全量上传）。
  Future<String> setMode(StorageMode m, {bool silent = false}) async {
    if (m == _mode) return '已是当前模式';
    final wasInvolvesServer = _mode.involvesServer;
    final from = _mode;
    _mode = m;
    await AppDb.instance.setSetting(AppConfig.storageModeKey, m.name);
    notifyListeners();
    if (m.involvesServer && !silent && !wasInvolvesServer) {
      // 存量数据首次切到含服务器模式：一次性全量上传 + 合并（要求 #5）。
      unawaited(_runMutex(() => syncOnStart()));
      return switch (from) {
        StorageMode.local =>
          '已切换到「${m.label}」。本地存量数据将一次性全量上传到云端并完成合并；'
              '上传期间若云端暂无数据，以本地为基准建立云端副本。',
        _ => '已切换到「${m.label}」，正在同步…',
      };
    }
    if (!m.involvesServer) {
      // 切回仅本地：不再访问云端业务接口，最近一次同步结果保留在本地。
      _lastError = null;
      notifyListeners();
    }
    return '已切换到「${m.label}」。';
  }

  /// 登录/启动时执行的同步：
  /// - 首次（本地无同步水位）：全量 merge，先推送本地（含墓碑）再落地服务器权威快照，
  ///   完成存量数据一次性全量上传（要求 #5）与双向对账；
  /// - 后续：按同步水位（sync_lwm）增量 pull，只拉取服务器上更新时间大于水位的行；
  ///   双向模式下同时把本地新改动推上去。
  /// 冲突以服务器最新为准；命中服务器删除墓碑则应用删除。
  Future<void> syncOnStart() async {
    if (!canSync) return;
    final lwm = await _lwm();
    if (lwm > 0) {
      // 增量拉取：_ts > lwm 的行（含墓碑）
      final res = await ApiClient.instance.pullSync(lwm);
      final serverTables = res['tables'];
      if (serverTables is Map) {
        await _applyServerTables(serverTables);
      }
      final ts = (res['serverTs'] as num?)?.toInt() ?? 0;
      if (ts > lwm) await _setLwm(ts);
      if (_mode == StorageMode.both) {
        await _pushNow();
      }
    } else {
      // 首次：全量双向合并
      final tables = await _buildTables();
      final res = await ApiClient.instance.mergeSync(tables);
      final serverTables = res['tables'];
      if (serverTables is Map) {
        // 首次合并不收集冲突（刚上传的本地快照与服务器快照时间戳一致，
        // 视为同一版本），直接以服务器权威快照落地。
        await _applyServerTables(serverTables, collectConflicts: false);
      }
      await AppDb.instance.clearTombstones();
      await _setLwm((res['serverTs'] as num?)?.toInt() ?? now());
    }
    _lastSyncAt = now();
    _lastError = null;
    notifyListeners();
  }

  /// 本地数据发生变化后的回调（写入路径已统一注入 updated_at 与墓碑）。
  /// 仅本地模式：直接忽略，不访问云端。
  void onLocalChanged() {
    if (_mode == StorageMode.local) return;
    if (!canSync) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_runMutex(() => _pushNow()));
    });
  }

  /// 立即后台推送本地全部数据（含墓碑）到云端。供页面「立即同步」调用。
  Future<void> pushNow() => _runMutex(() => _pushNow());

  /// 删除服务器上本账号的全部同步数据（存储方式切回「仅本地」时的可选项）。
  /// 仅清除云端命名空间，本地数据保持不变；同时清空本地同步水位，
  /// 之后再次切回含服务器模式时会按首次全量重新上传。
  /// 返回服务器返回的被删除行数。
  Future<int> deleteServerData() async {
    if (!canSync) return 0;
    final res = await ApiClient.instance.deleteServerSync();
    final rows = (res['deletedRows'] as num?)?.toInt() ?? 0;
    await _setLwm(0);
    _lastSyncAt = now();
    _lastError = null;
    notifyListeners();
    return rows;
  }

  Future<void> _pushNow() async {
    if (!canSync) return;
    final tables = await _buildTables();
    final res = await ApiClient.instance.pushSync(tables);
    await AppDb.instance.clearTombstones();
    final ts = (res['serverTs'] as num?)?.toInt() ?? 0;
    if (ts > (await _lwm())) {
      await _setLwm(ts);
    }
    _lastSyncAt = now();
    _lastError = null;
    notifyListeners();
  }

  /// 组装同步负载：各同步表全部行（附加 _ts）+ 删除墓碑（混入对应表列表）。
  Future<Map<String, dynamic>> _buildTables() async {
    final tombs = <String, List<Map<String, dynamic>>>{};
    for (final tb in await AppDb.instance.getTombstones()) {
      final t = '${tb['table_name'] ?? ''}';
      if (!tables.contains(t)) continue;
      final list = tombs.putIfAbsent(t, () => []);
      list.add({
        'id': tb['row_id'],
        '_deleted': true,
        '_ts': tb['deleted_at'] ?? 0,
      });
    }
    final out = <String, dynamic>{};
    for (final t in tables) {
      final rows = <Map<String, dynamic>>[];
      for (final r in await AppDb.instance.syncRows(t)) {
        final m = Map<String, dynamic>.from(r);
        m['_ts'] = _rowTs(t, m);
        rows.add(m);
      }
      rows.addAll(tombs[t] ?? const []);
      out[t] = rows;
    }
    return out;
  }

  /// 落地服务器数据到本地。冲突处理：
  /// - 同一行比较 `_ts`，服务器更新才覆盖；
  /// - 本地更新更晚（尚未推送）的行保留，等待下一轮推送合并；
  /// - 墓碑按更晚时间删除；
  /// - [collectConflicts]：askMe 策略下把「将被覆盖」的行收集为待决策冲突，
  ///   由用户选择采用云端还是保留本地（默认开启；首次全量合并关闭）。
  Future<void> _applyServerTables(
    Map<dynamic, dynamic> serverTables, {
    bool collectConflicts = true,
  }) async {
    for (final entry in serverTables.entries) {
      final t = '${entry.key}';
      if (!tables.contains(t)) continue;
      final rows = entry.value;
      if (rows is! List) continue;
      for (final raw in rows) {
        if (raw is! Map) continue;
        final id = raw['id'];
        if (id is! int) continue;
        final serverTs = _int(raw['_ts']);
        final local = await AppDb.instance.syncRowById(t, id);
        if (raw['_deleted'] == true) {
          // 服务器删除墓碑：仅当本地行不更新于墓碑时才删除。
          if (local != null && _rowTs(t, local) <= serverTs) {
            await AppDb.instance.deleteRowSilently(t, id);
          }
          continue;
        }
        if (local != null && _rowTs(t, local) > serverTs) {
          continue; // 本地更新，保留并在下一轮推送
        }
        if (_policy == SyncConflictPolicy.askMe &&
            collectConflicts &&
            local != null &&
            !await _wasDismissed(t, id, serverTs)) {
          // 云端版本更新、本地也有版本：收集为待决策冲突，本轮先不覆盖本地。
          await _queueConflict(
            t,
            id,
            local,
            serverTs,
            Map<String, Object?>.from(raw),
          );
          continue;
        }
        await AppDb.instance.upsertSyncRow(t, Map<String, Object?>.from(raw));
      }
    }
  }

  /// 收集一条冲突（同一行去重：后到的同类冲突覆盖先前的）。
  Future<void> _queueConflict(
    String t,
    int id,
    Map<String, Object?> local,
    int serverTs,
    Map<String, Object?> serverRow,
  ) async {
    await _ensureKeepLocalCache();
    SyncConflict item = SyncConflict(
      table: t,
      id: id,
      title: _titleOf(t, local),
      localTs: _rowTs(t, local),
      serverTs: serverTs,
      serverRow: serverRow,
    );
    final idx = _pending.indexWhere((c) => c.key == item.key);
    if (idx >= 0) {
      _pending[idx] = item;
    } else {
      _pending.add(item);
    }
    notifyListeners();
  }

  /// 采用云端版本（覆盖本地）：批量解决给定冲突。
  Future<void> applyServerVersions(List<SyncConflict> items) => _runMutex(() async {
    if (items.isEmpty) return;
    for (final c in items) {
      await AppDb.instance.upsertSyncRow(c.table, c.serverRow);
    }
    _pending.removeWhere((x) => items.any((i) => i.key == x.key));
    notifyListeners();
  });

  /// 保留本地版本：批量解决给定冲突，并把该行加入忽略集（同版本不再重复提示）。
  Future<void> keepLocalVersions(List<SyncConflict> items) => _runMutex(() async {
    if (items.isEmpty) return;
    for (final c in items) {
      _keepLocalCache[c.key] = c.serverTs;
    }
    await _persistKeepLocalCache();
    _pending.removeWhere((x) => items.any((i) => i.key == x.key));
    notifyListeners();
  });

  /// 清空待处理冲突（不做数据变更，仅丢弃提示）。
  void clearPendingConflicts() {
    if (_pending.isEmpty) return;
    _pending.clear();
    notifyListeners();
  }

  /// 按「保留较新」策略自动解决一条冲突（autoNewest 收尾用）。
  Future<void> _resolveAuto(SyncConflict c) async {
    final local = await AppDb.instance.syncRowById(c.table, c.id);
    if (local == null || _rowTs(c.table, local) <= c.serverTs) {
      await AppDb.instance.upsertSyncRow(c.table, c.serverRow);
    }
    _pending.removeWhere((x) => x.key == c.key);
    notifyListeners();
  }

  /// 该行是否命中用户「保留本地」忽略集（同服务器版本不再重复收集）。
  Future<bool> _wasDismissed(String t, int id, int serverTs) async {
    await _ensureKeepLocalCache();
    return _keepLocalCache['$t:$id'] == serverTs;
  }

  Future<void> _ensureKeepLocalCache() async {
    if (_keepLocalLoaded) return;
    _keepLocalLoaded = true;
    try {
      final s = await AppDb.instance.getSetting(AppConfig.syncKeepLocalKey);
      if (s != null && s.isNotEmpty) {
        final m = jsonDecode(s);
        if (m is Map) {
          for (final e in m.entries) {
            _keepLocalCache['${e.key}'] = (e.value as num).toInt();
          }
        }
      }
    } catch (_) {
      // 忽略集解析失败按空处理。
    }
  }

  Future<void> _persistKeepLocalCache() async {
    await AppDb.instance.setSetting(
      AppConfig.syncKeepLocalKey,
      jsonEncode(_keepLocalCache),
    );
  }

  /// 表的中文名（面向用户展示用）。
  static String _tableLabel(String t) => switch (t) {
    'customers' => '客户',
    'projects' => '项目',
    'payments' => '收款',
    'quotes' => '报价',
    'pending_collections' => '待收款',
    'milestones' => '里程碑',
    'contracts' => '合同',
    _ => t,
  };

  /// 冲突条目的展示名称：客户名 / 项目名 / 报价标题等；无名称时回退为「表名 #id」。
  static String _titleOf(String t, Map<String, Object?> row) {
    final name = row['name'] ?? row['title'] ?? '';
    final s = '$name'.trim();
    if (s.isNotEmpty) return s;
    return '${_tableLabel(t)} #${row['id']}';
  }

  /// 行时间戳：updated_at 与业务时间（paid_at/settled_at/signed_at/created_at）
  /// 的最大者，作为该行的权威修改时间参与冲突比较。
  static int _rowTs(String t, Map<String, Object?> m) {
    var ts = _int(m['updated_at']);
    if (ts <= 0) ts = _int(m['created_at']);
    if (t == 'payments') ts = math.max(ts, _int(m['paid_at']));
    if (t == 'pending_collections') ts = math.max(ts, _int(m['settled_at']));
    if (t == 'contracts') ts = math.max(ts, _int(m['signed_at']));
    return ts;
  }

  static int _int(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

  Future<int> _lwm() async =>
      int.tryParse(await AppDb.instance.getSetting(AppConfig.syncLwmKey) ?? '') ??
      0;

  Future<void> _setLwm(int v) =>
      AppDb.instance.setSetting(AppConfig.syncLwmKey, '$v');

  static int now() => DateTime.now().millisecondsSinceEpoch;

  /// 简易互斥：同一时刻只允许一个同步任务执行。
  Future<void> _runMutex(Future<void> Function() fn) async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();
    try {
      await fn();
    } catch (e) {
      // token 失效独立分支：不是普通网络错误，标记鉴权失效供页面跳转登录。
      if (e is TokenInvalidException) {
        _authExpired = true;
        _lastError = '登录已失效，请重新登录';
      } else {
        _lastError = '同步失败：$e';
        // 全局友好提示（错误文本变化时才提示一次，避免刷屏）：指向页面重试。
        ErrorReporter.instance.notify('云端数据同步失败，请稍后在设置中重试');
      }
      notifyListeners();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}
