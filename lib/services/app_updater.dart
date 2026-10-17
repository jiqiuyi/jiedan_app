import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'error_reporter.dart';

/// App 内更新下载与安装（v1.46.2 新增）。
///
/// 点击「立即更新」后由本服务通过 flutter_downloader 在后台下载新版 APK：
/// - 系统通知栏展示下载进度（showNotification=true）；
/// - 下载目标为 App 私有目录（getApplicationSupportDirectory()/downloads），无需存储权限；
/// - 下载完成后自动拉起系统安装界面（原生 MethodChannel 经 FileProvider 生成
///   content:// URI），全程不跳转浏览器。
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const String _installChannelName = 'com.jiedan.guanjia/apk_install';
  static const String _portName = 'app_updater_download_port';

  final MethodChannel _installChannel =
      const MethodChannel(_installChannelName);

  bool _inited = false;
  ReceivePort? _port;
  /// 最近一次下载的 URL / 版本（complete 回调时记录，供失败后「重新尝试」
  /// 重新下载使用；进程存活期间有效）。
  String? _lastDownloadUrl;
  String? _lastVersion;

  /// 应用启动时初始化：注册下载回调（后台 isolate 事件转发到主 isolate）。
  /// 失败不阻断启动（仅失去自动安装能力，可手动重试）。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await FlutterDownloader.initialize(debug: false);
      _port = ReceivePort();
      // 防热重启/重复注册：先移除旧 port（旧 isolate 已销毁时 lookup 会拿到
      // 死 port 导致回调丢失），再注册当前 port。
      IsolateNameServer.removePortNameMapping(_portName);
      IsolateNameServer.registerPortWithName(_port!.sendPort, _portName);
      _port!.listen(_onDownloadEvent);
      await FlutterDownloader.registerCallback(_downloadCallback);
    } catch (e) {
      debugPrint('AppUpdater init failed: $e');
    }
  }

  /// 开始后台下载新版 APK；下载完成回调自动触发安装。
  Future<void> startDownload(String url, String version) async {
    _lastDownloadUrl = url;
    _lastVersion = version;
    try {
      final dir = await _ensureDownloadDir();
      final fileName = 'jiedan_guanjia_v$version.apk';
      final target =
          File('${dir.path}${Platform.pathSeparator}$fileName');
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {
          // 残留旧包删除失败不阻塞下载（下载器会覆盖）
        }
      }
      final taskId = await FlutterDownloader.enqueue(
        url: url,
        savedDir: dir.path,
        fileName: fileName,
        showNotification: true, // 通知栏展示下载进度
        // 下载完成通知点击直接打开 APK 拉起系统安装界面（flutter_downloader
        // 1.12.1 仅当此项为 true 时才会为完成通知设置 contentIntent，否则
        // 点击通知无任何响应，App 也不会被唤起）
        openFileFromNotification: true,
      );
      if (taskId == null || taskId.isEmpty) {
        _showSnack('开始下载失败，请稍后重试');
        return;
      }
      _showSnack('已开始后台下载，完成后自动安装');
    } catch (_) {
      _showSnack('开始下载失败，请稍后重试');
    }
  }

  /// 后台 isolate 下载回调（必须 @pragma 防 release 模式树摇）。
  @pragma('vm:entry-point')
  static void _downloadCallback(String id, int status, int progress) {
    final send = IsolateNameServer.lookupPortByName(_portName);
    send?.send([id, status, progress]);
  }

  void _onDownloadEvent(dynamic data) {
    if (data is! List || data.length < 2) return;
    final id = data[0] as String;
    final status = DownloadTaskStatus.fromInt(data[1] as int? ?? -1);
    if (status == DownloadTaskStatus.complete) {
      _installByTaskId(id);
    } else if (status == DownloadTaskStatus.failed) {
      _showSnack('新版本下载失败，请稍后重试');
    } else if (status == DownloadTaskStatus.canceled) {
      _showSnack('已取消更新下载');
    }
  }

  Future<void> _installByTaskId(String taskId) async {
    try {
      String? path;
      final tasks = await FlutterDownloader.loadTasks();
      if (tasks != null) {
        final task = tasks.where((t) => t.taskId == taskId).firstOrNull;
        if (task != null && task.filename != null) {
          path =
              '${task.savedDir}${Platform.pathSeparator}${task.filename}';
          // 记录最近下载信息，供安装失败后「重新尝试」重新下载使用。
          _lastDownloadUrl = task.url;
          _lastVersion = _versionFromApkName(task.filename!);
        }
      }
      // 兜底：回调里 loadTasks 匹配不到 taskId（release 树摇 / 数据库丢失）时，
      // 扫描下载目录中最新的 .apk 直接安装，避免静默失败。
      path ??= await _findLatestApk();
      if (path == null) {
        _showSnack('新版本已下载，但未找到安装包，请稍后重试');
        return;
      }
      await _installApk(path);
    } catch (_) {
      _showSnack('下载完成但安装失败，请稍后重试');
    }
  }

  /// 扫描下载目录中最新的 .apk 文件（taskId 匹配失败时的兜底）。
  Future<String?> _findLatestApk() async {
    try {
      final dir = await _ensureDownloadDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.apk'))
          .toList()
        ..sort((a, b) =>
            b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      if (files.isEmpty) return null;
      return files.first.path;
    } catch (_) {
      return null;
    }
  }

  /// 消费原生侧记录的通知点击 / APK 打开意图并触发安装。
  /// 冷启动（onCreate 置位）与前台恢复（onNewIntent 置位）后由 main.dart 调用。
  /// 若无待消费意图，则兜底扫描下载目录中比当前版本新的 APK（覆盖
  /// 「后台下载完成但回调丢失 / 通知被清」场景），弹窗让用户决定是否安装。
  Future<void> checkPendingInstall() async {
    try {
      final pending = await _installChannel
          .invokeMapMethod<String, dynamic>('consumeNotificationInstall');
      if (pending == null || pending.isEmpty) {
        await _offerPendingApkOnStartup();
        return;
      }
      final taskId = pending['taskId'] as String?;
      final path = pending['path'] as String?;
      if (taskId != null && taskId.isNotEmpty) {
        await _installByTaskId(taskId);
      } else if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (f.existsSync()) {
          await _installApk(path);
        } else {
          _showSnack('安装包不存在，请重新下载更新');
        }
      }
    } catch (_) {
      _showSnack('安装失败，请稍后重试');
    }
  }

  /// 启动兜底：下载目录存在比当前版本新的 APK 时弹窗询问安装。
  /// 用 SharedPreferences 记录已询问过的文件名，避免每次启动重复打扰。
  static const String _offeredApkKey = 'update_install_offered_apk';

  Future<void> _offerPendingApkOnStartup() async {
    try {
      final dir = await _ensureDownloadDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.apk'))
          .toList()
        ..sort((a, b) =>
            b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      if (files.isEmpty) return;
      final latest = files.first.path;
      final apkName = latest.split(Platform.pathSeparator).last;
      final apkVersion = _versionFromApkName(apkName);
      if (apkVersion == null) return;
      final info = await PackageInfo.fromPlatform();
      if (!_isVersionNewer(apkVersion, info.version)) return;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_offeredApkKey) == apkName) return;
      await prefs.setString(_offeredApkKey, apkName);

      final ctx = appNavigatorKey.currentContext;
      if (ctx == null) return;
      if (!ctx.mounted) return;
      await showDialog<void>(
        context: ctx,
        builder: (dialogCtx) => AlertDialog(
          title: Text('检测到新版本 v$apkVersion'),
          content: const Text('新版本安装包已下载完成，是否现在安装？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('暂不'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                unawaited(_installApk(latest));
              },
              child: const Text('立即安装'),
            ),
          ],
        ),
      );
    } catch (_) {
      // 兜底失败静默即可：用户仍可走「检查更新」主动下载
    }
  }

  /// 拉起系统安装界面（原生侧经 FileProvider 提供 content:// URI）。
  /// 失败时弹可见对话框（原因 + 手动安装 + 重新尝试），绝不静默。
  Future<void> _installApk(String path, {String? reason}) async {
    try {
      final ok = await _installChannel.invokeMethod<bool>('installApk', path);
      if (ok != true) {
        _showInstallFailedDialog(
          reason ?? '系统未启动安装界面，请重试',
          path: path,
        );
      }
    } on PlatformException catch (e) {
      if (e.code == 'need_unknown_sources') {
        _showNeedUnknownSourcesDialog();
      } else {
        _showInstallFailedDialog(e.message ?? '请稍后重试', path: path);
      }
    } catch (e) {
      _showInstallFailedDialog('$e', path: path);
    }
  }

  /// 安装失败兜底对话框：展示失败原因，并提供「手动安装」（再次拉起系统
  /// 安装器）与「重新尝试」（重新下载后自动安装）两条出路。
  void _showInstallFailedDialog(String reason, {String? path}) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    final canReDownload = _lastDownloadUrl != null && _lastVersion != null;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('新版本安装失败'),
        content: Text(
          '下载已完成，但安装未成功：\n$reason\n\n'
          '可尝试手动安装；若仍失败，可重新下载后再次安装。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('关闭'),
          ),
          if (canReDownload)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                unawaited(startDownload(
                  _lastDownloadUrl!,
                  _lastVersion!,
                ));
              },
              child: const Text('重新尝试'),
            ),
          if (path != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                unawaited(_installApk(path));
              },
              child: const Text('手动安装'),
            ),
        ],
      ),
    );
  }

  /// 从 APK 文件名（jiedan_guanjia_v1.46.8.apk）解析版本号。
  String? _versionFromApkName(String name) {
    final m = RegExp(r'v(\d+\.\d+\.\d+)\.apk$').firstMatch(name);
    return m?.group(1);
  }

  /// 简单版本号比较：a 是否比 b 新（逐段数字比较）。
  bool _isVersionNewer(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  void _showNeedUnknownSourcesDialog() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('需要允许安装未知来源应用'),
        content: const Text(
            '系统未允许安装未知来源应用，将无法弹出安装界面。\n'
            '请点击「去开启」跳转系统设置：\n'
            '华为/荣耀设备：设置 → 更多安全设置 → 外部来源应用（或安装外部来源应用）→ 允许本应用。\n'
            '其他设备：设置 → 安全 → 安装未知应用 → 允许本应用。\n'
            '开启后返回本页重试即可。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              unawaited(
                  _installChannel.invokeMethod('openUnknownSourcesSettings'));
            },
            child: const Text('去开启'),
          ),
        ],
      ),
    );
  }

  Future<Directory> _ensureDownloadDir() async {
    final base = await getApplicationSupportDirectory();
    final dir =
        Directory('${base.path}${Platform.pathSeparator}downloads');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  void _showSnack(String msg) {
    appMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
  }
}
