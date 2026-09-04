import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 全局导航 / 消息 key：供非 Widget 环境（全局异常处理器、后台服务）弹提示使用。
/// MaterialApp 需分别挂载到 navigatorKey / scaffoldMessengerKey。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 全局异常捕获与日志（v1.20.0）。
///
/// 捕获范围：
/// - [FlutterError.onError]：框架层异常（build / layout / 断言）；
/// - [PlatformDispatcher.onError]：平台层异步异常（返回 true 阻止进程崩溃）；
/// - runZonedGuarded（见 main.dart）：兜底未被上述二者捕获的异步异常。
///
/// 行为：统一写入应用文档 logs/ 下按天滚动的错误日志（保留最近 3 天），
/// 并对用户给出友好提示；任何底层技术细节（堆栈 / 异常类名 / Widget 名）
/// 都不会对用户展示，只进入本地日志。
class ErrorReporter {
  ErrorReporter._();
  static final ErrorReporter instance = ErrorReporter._();

  /// 保留的最近日志文件天数。
  static const int _retainCount = 3;

  /// 单文件大小上限，超过后截断保留尾部（保留新信息）。
  static const int _maxBytes = 512 * 1024;
  static const int _keptBytes = 256 * 1024;

  /// 同内容提示的最小间隔，避免后台异常反复刷屏。
  static const Duration _notifyGap = Duration(seconds: 5);

  bool _installed = false;
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 安装全局异常处理（幂等）。必须在 runApp 之前调用。
  void install() {
    if (_installed) return;
    _installed = true;

    FlutterError.onError = (FlutterErrorDetails details) {
      logError('flutter', details.exception, details.stack);
      // 保留默认行为：debug 下仍展示错误定位，release 下不弹红屏不白屏。
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      logError('platform', error, stack);
      notify();
      return true; // 捕获平台层未处理异常，防止应用直接崩溃退出。
    };
  }

  /// 写入错误日志（按天滚动，保留最近 [_retainCount] 天，超限截断尾部）。
  /// 异步执行并吞掉自身异常，日志能力绝不反向影响主流程。
  Future<void> logError(String tag, Object error, StackTrace? stack) async {
    try {
      final dir = await _logDir();
      final now = DateTime.now();
      final f = File(p.join(dir.path, 'error_${_stamp(now)}.log'));
      final buf = StringBuffer()
        ..writeln('[$now] [$tag] $error')
        ..writeln('  ${stack ?? '(无堆栈)'}');
      await f.writeAsString(buf.toString(), mode: FileMode.append);
      if (f.lengthSync() > _maxBytes) {
        final bytes = await f.readAsBytes();
        final skip = bytes.length - _keptBytes;
        if (skip > 0) {
          await f.writeAsBytes(bytes.sublist(skip));
        }
      }
      await _prune(dir);
    } catch (_) {
      // 日志写入失败不影响主流程。
    }
  }

  /// 全局友好提示（节流：最短间隔 [_notifyGap]，避免连续异常刷屏）。
  /// runApp 尚未挂载 messenger 时静默丢弃（此时也无用户界面可提示）。
  void notify([String? message]) {
    final now = DateTime.now();
    if (now.difference(_lastNotifyAt) < _notifyGap) return;
    _lastNotifyAt = now;
    final messenger = appMessengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message ?? '操作未能完成，请稍后重试'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<Directory> _logDir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'logs'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _prune(Directory dir) async {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('error_'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(_retainCount)) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  static String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
