import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'theme.dart';
import 'pages/home_shell.dart';
import 'services/error_reporter.dart';
import 'services/notify_service.dart';
import 'services/pay_notice_reporter.dart';
import 'services/signature_guard.dart';
import 'services/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局异常捕获（v1.20.0）：框架层 / 平台层 / 未捕获异步异常统一入库并友好提示。
  ErrorReporter.instance.install();
  // 兜底未捕获的异步异常（runZonedGuarded），日志入库并防崩溃白屏。
  runZonedGuarded(() async {
    // 防重打包自签名校验（仅 release）：包被二次签名/重打包则拒绝进入应用
    try {
      await SignatureGuard.instance.verifyOnLaunch();
    } catch (_) {
      runApp(const TamperedApp());
      return;
    }
    await AppState.instance.load();
    // 初始化本地催款提醒通知（完全本地，不涉及网络）
    await NotifyService.instance.init();
    // 初始化数据存储方式（v1.14.0）：读取持久化模式；
    // 仅本地模式不访问云端；含服务器模式会在后台执行一次启动同步。
    await SyncService.instance.init();
    runApp(const JieDanApp());
    // 启动后静默核对一次到账记录（失败进重试队列，不阻塞启动）
    unawaited(PayNoticeReporter.instance.retryPending());
    unawaited(PayNoticeReporter.instance.uploadPending());
  }, (Object error, StackTrace stack) {
    ErrorReporter.instance.logError('zone', error, stack);
    ErrorReporter.instance.notify();
  });
}

/// 签名被篡改（重打包/二次签名）时的拒绝进入页。
class TamperedApp extends StatelessWidget {
  const TamperedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: AppTheme.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.gpp_bad_outlined,
                    size: 64, color: AppTheme.danger),
                const SizedBox(height: 16),
                const Text(
                  '应用签名校验失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  '当前安装包可能已被重新打包或篡改，为保障您的数据安全，应用已停止运行。\n请从官方渠道重新下载安装。',
                  textAlign: TextAlign.center,
                  style: TextStyle(height: 1.6),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('退出应用'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class JieDanApp extends StatelessWidget {
  const JieDanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,
      title: '接单管家',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      // 中文本地化：让系统组件（日期选择器/时间选择器等）显示中文
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}
