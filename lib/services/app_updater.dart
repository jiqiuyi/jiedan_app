import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:path_provider/path_provider.dart';

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

  /// 应用启动时初始化：注册下载回调（后台 isolate 事件转发到主 isolate）。
  /// 失败不阻断启动（仅失去自动安装能力，可手动重试）。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await FlutterDownloader.initialize(debug: false);
      _port = ReceivePort();
      IsolateNameServer.registerPortWithName(_port!.sendPort, _portName);
      _port!.listen(_onDownloadEvent);
      await FlutterDownloader.registerCallback(_downloadCallback);
    } catch (e) {
      debugPrint('AppUpdater init failed: $e');
    }
  }

  /// 开始后台下载新版 APK；下载完成回调自动触发安装。
  Future<void> startDownload(String url, String version) async {
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
        openFileFromNotification: false, // 下载完成后由本服务自动拉起安装
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
      final tasks = await FlutterDownloader.loadTasks();
      if (tasks == null) return;
      final task = tasks.where((t) => t.taskId == taskId).firstOrNull;
      if (task == null || task.filename == null) return;
      final path =
          '${task.savedDir}${Platform.pathSeparator}${task.filename}';
      await _installApk(path);
    } catch (_) {
      _showSnack('下载完成但安装失败，请稍后重试');
    }
  }

  /// 拉起系统安装界面（原生侧经 FileProvider 提供 content:// URI）。
  Future<void> _installApk(String path) async {
    try {
      final ok = await _installChannel.invokeMethod<bool>('installApk', path);
      if (ok != true) {
        _showSnack('安装失败，请稍后重试');
      }
    } on PlatformException catch (e) {
      if (e.code == 'need_unknown_sources') {
        _showNeedUnknownSourcesDialog();
      } else {
        _showSnack('安装失败：${e.message ?? '请稍后重试'}');
      }
    } catch (_) {
      _showSnack('安装失败，请稍后重试');
    }
  }

  void _showNeedUnknownSourcesDialog() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('需要允许安装未知来源应用'),
        content: const Text(
            '系统未允许安装未知来源应用，请前往系统设置开启「允许安装未知应用」后重新更新。'),
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
