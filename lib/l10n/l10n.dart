/// 轻量国际化访问类（lib/l10n/l10n.dart）
///
/// 设计：
/// - 自建 Map 双字典（zh_CN / en_US），不引入第三方 i18n 包；
/// - `L10n.instance` 全局单例，`t(key)` 取翻译，支持 `{name}` 占位符插值；
/// - `locale` 为 ValueNotifier（监听 Locale 变化）：App 启动时按系统语言初始化，
///   运行时通过 `setPref` 切换（zh / en / system），切换后 MaterialApp 全局重建；
/// - 语言偏好持久化到 SharedPreferences（key: lang_pref）；
/// - 仅影响文案语言，日期/数字格式保持既有行为。
library;

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'zh_CN.dart';
import 'en_US.dart';

/// 语言偏好：跟随系统 / 中文 / English
enum LangPref { system, zh, en }

class L10n {
  L10n._();
  static final L10n instance = L10n._();

  /// 偏好持久化键（SharedPreferences）
  static const String prefKey = 'lang_pref';

  /// 当前生效的 locale（MaterialApp 监听此值）
  final ValueNotifier<Locale> locale = ValueNotifier(const Locale('zh', 'CN'));

  LangPref _pref = LangPref.system;

  Locale get current => locale.value;
  bool get isZh => locale.value.languageCode == 'zh';

  /// 启动时初始化：读取持久化偏好并应用
  Future<void> init() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(prefKey) ?? LangPref.system.name;
    _pref = LangPref.values
        .firstWhere((e) => e.name == raw, orElse: () => LangPref.system);
    _apply();
  }

  /// 设置语言偏好并立即生效（zh / en / system）
  Future<void> setPref(LangPref p) async {
    if (_pref == p) return;
    _pref = p;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(prefKey, p.name);
    _apply();
  }

  LangPref get pref => _pref;

  /// 翻译：按当前语言取字典；未命中回退原文；支持 {name} 插值。
  String t(String key, {Map<String, String>? args}) {
    final map = isZh ? zhCN : enUS;
    var s = map[key] ?? key;
    if (args != null) {
      args.forEach((k, v) {
        s = s.replaceAll('{$k}', v);
      });
    }
    return s;
  }

  /// 中文原文（供需要固定中文的场合，如合同模板）
  String zh(String key, {Map<String, String>? args}) {
    var s = zhCN[key] ?? key;
    if (args != null) {
      args.forEach((k, v) {
        s = s.replaceAll('{$k}', v);
      });
    }
    return s;
  }

  void _apply() {
    switch (_pref) {
      case LangPref.zh:
        locale.value = const Locale('zh', 'CN');
      case LangPref.en:
        locale.value = const Locale('en');
      case LangPref.system:
        locale.value = _systemLocale();
    }
  }

  Locale _systemLocale() {
    final sys = PlatformDispatcher.instance.locale;
    return sys.languageCode.toLowerCase() == 'zh'
        ? const Locale('zh', 'CN')
        : const Locale('en');
  }
}
