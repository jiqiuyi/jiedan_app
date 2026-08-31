import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_state.dart';
import 'theme.dart';
import 'pages/home_shell.dart';
import 'services/notify_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.instance.load();
  // 初始化本地催款提醒通知（完全本地，不涉及网络）
  await NotifyService.instance.init();
  runApp(const JieDanApp());
}

class JieDanApp extends StatelessWidget {
  const JieDanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
