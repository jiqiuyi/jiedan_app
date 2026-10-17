import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'database.dart';
import 'theme.dart';
import 'pages/home_shell.dart';
import 'services/error_reporter.dart';
import 'services/notify_service.dart';
import 'services/app_updater.dart';
import 'services/pay_notice_reporter.dart';
import 'services/signature_guard.dart';
import 'services/sync_service.dart';
import 'services/ledger_widget_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局异常捕获（v1.20.0）：框架层 / 平台层 / 未捕获异步异常统一入库并友好提示。
  ErrorReporter.instance.install();
  // 兜底未捕获的异步异常（runZonedGuarded），日志入库并防崩溃白屏。
  runZonedGuarded(() async {
    // 防重打包自签名校验（仅 release）：包被二次签名/重打包时提示，
    // 允许用户确认来源后继续使用（三星/第三方应用商店重签的合法安装不再被直接拒绝）。
    final sigOk = await _safeInit(
        'signature', () => SignatureGuard.instance.verifyOnLaunch());
    if (!sigOk) {
      runApp(SignatureWarningApp(
        onContinue: () async {
          await _initAppServices();
          runApp(const JieDanApp());
          _schedulePostLaunch();
        },
        onExit: () => SystemNavigator.pop(),
      ));
      return;
    }
    await _initAppServices();
    runApp(const JieDanApp());
    _schedulePostLaunch();
  }, (Object error, StackTrace stack) {
    ErrorReporter.instance.logError('zone', error, stack);
    ErrorReporter.instance.notify();
  });
}

/// 启动阶段服务初始化：任一步失败仅记录日志并降级，
/// 保证主界面必定能渲染（单点异常不再导致 runApp 不执行 -> 白屏打不开）。
Future<void> _initAppServices() async {
  await _safeInit('app_state', () => AppState.instance.load());
  await _safeInit('pending_invite',
      () => AppState.instance.restorePendingInviteCode());
  await _safeInit('clipboard',
      () => AppState.instance.captureClipboardInviteCode());
  await _safeInit('notify', () => NotifyService.instance.init());
  await _safeInit('app_updater', () => AppUpdater.instance.init());
  await _safeInit('sync', () => SyncService.instance.init());
}

/// 单步初始化安全包装：失败记录日志并返回 false，不向启动链路抛异常。
Future<bool> _safeInit(String tag, Future<void> Function() fn) async {
  try {
    await fn();
    return true;
  } catch (e, st) {
    ErrorReporter.instance.logError('init_$tag', e, st);
    return false;
  }
}

/// runApp 后启动的后台任务（原 main 尾部逻辑，抽出供签名确认页复用）。
void _schedulePostLaunch() {
  // 启动后静默核对一次到账记录（失败进重试队列，不阻塞启动）
  unawaited(PayNoticeReporter.instance.retryPending());
  unawaited(PayNoticeReporter.instance.uploadPending());
  // 启动后巡检本地待办提醒（v1.24.0：回款到期 / 报价待确认，基于本地数据，不依赖服务器）
  unawaited(NotifyService.instance.checkLocalReminders());
  // App 在线期间每小时再巡检一次，跨过到期时间点也能及时本地提醒（轻量，仅查本地 SQLite）
  Timer.periodic(const Duration(hours: 1), (_) {
    unawaited(NotifyService.instance.checkLocalReminders());
  });
  // 启动后静默执行一次数据库自检（表结构完整性 / 数据可恢复性），结果留痕，
  // 可在「数据管理」页查看；失败不阻断启动。
  unawaited(AppDb.instance.backgroundHealthCheck());
}

/// 签名被篡改（重打包/二次签名）时的提示页：由用户决定退出或继续使用。
/// 三星 / 第三方应用商店会对 APK 重签，直接拒绝会把合法用户挡在门外（表现同「打不开」）；
/// 改为显式告知风险并保留选择权，防破解同时不误伤真实用户。
class SignatureWarningApp extends StatelessWidget {
  const SignatureWarningApp({
    super.key,
    required this.onContinue,
    required this.onExit,
  });

  final Future<void> Function() onContinue;
  final VoidCallback onExit;

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
                const Icon(Icons.gpp_maybe_outlined,
                    size: 64, color: AppTheme.warn),
                const SizedBox(height: 16),
                const Text(
                  '安装包签名校验未通过',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  '当前安装包签名与官方版本不一致，可能来自第三方应用商店或安装包被修改，存在账号与数据安全风险。\n请优先从官方渠道下载安装；如确认来源可信，可选择继续使用。',
                  textAlign: TextAlign.center,
                  style: TextStyle(height: 1.6),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onExit,
                  child: const Text('退出应用'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => onContinue(),
                  child: const Text('继续使用'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class JieDanApp extends StatefulWidget {
  const JieDanApp({super.key});

  @override
  State<JieDanApp> createState() => _JieDanAppState();
}

class _JieDanAppState extends State<JieDanApp> with WidgetsBindingObserver {
  /// HomeShell 的 State 引用：桌面小组件「记一笔」拉起时直接弹极速记账面板。
  final GlobalKey<HomeShellState> _homeKey = GlobalKey<HomeShellState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 记账增删改 -> 刷新桌面小组件（v1.46.1）
    AppDb.onLedgerChanged = LedgerWidgetBridge.refresh;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 启动时同步一次小组件数据（补桌面添加后未触发过的场景）
      unawaited(LedgerWidgetBridge.refresh());
      // 冷启动：消费桌面小组件「记一笔」意图，直接弹出极速记账面板
      unawaited(_maybeOpenQuickLedger());
      // 冷启动：消费通知点击「下载完成」置位的安装意图（v1.46.4）
      unawaited(AppUpdater.instance.checkPendingInstall());
    });
  }

  @override
  void dispose() {
    AppDb.onLedgerChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 前台恢复：消费小组件「记一笔」意图（热启动）
      unawaited(_maybeOpenQuickLedger());
      // 前台恢复：消费通知点击「下载完成」置位的安装意图（v1.46.4）
      unawaited(AppUpdater.instance.checkPendingInstall());
    }
  }

  /// 若原生侧有未消费的 QUICK_LEDGER 意图，则直接拉起极速记账面板（不经过首页）。
  Future<void> _maybeOpenQuickLedger() async {
    final should = await LedgerWidgetBridge.consumeQuickLedger();
    if (!should) return;
    final shell = _homeKey.currentState;
    if (shell != null) shell.openQuickLedger();
  }

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
      home: HomeShell(key: _homeKey),
    );
  }
}
