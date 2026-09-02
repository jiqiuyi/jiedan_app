import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../constants.dart';
import '../database.dart';

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
        await _applyServerTables(serverTables);
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

  /// 落地服务器数据到本地：同一行比较 `_ts`，服务器更新才覆盖；墓碑按更晚时间删除。
  /// 本地更新更晚（尚未推送）的行保留，等待下一轮推送合并（避免覆盖本地新改动）。
  Future<void> _applyServerTables(Map<dynamic, dynamic> serverTables) async {
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
        await AppDb.instance.upsertSyncRow(t, Map<String, Object?>.from(raw));
      }
    }
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
      _lastError = '同步失败：$e';
      notifyListeners();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }
}
