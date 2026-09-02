import 'package:flutter/material.dart';

// 「接单管家」设计 Token —— 干净克制的 B 端工具气质
class AppTheme {
  static const Color primary = Color(0xFF4A5AF0); // 品牌蓝
  static const Color primaryDark = Color(0xFF3A46C4);
  static const Color accent = Color(0xFF16A085); // 收入绿
  static const Color warn = Color(0xFFE67E22); // 待收/提醒橙
  static const Color danger = Color(0xFFE74C3C);
  static const Color success = Color(0xFF27AE60); // 同步成功/健康态
  static const Color bg = Color(0xFFF6F7FB);
  static const Color card = Colors.white;
  static const Color bgCard = Color(0xFFEFF2F8); // 内嵌灰卡
  static const Color divider = Color(0xFFE3E7F0); // 分割线
  static const Color textMain = Color(0xFF1B2233);
  static const Color textSub = Color(0xFF8A93A6);

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        surface: bg,
      ),
      scaffoldBackgroundColor: bg,
      fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei'],
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: true,
        foregroundColor: textMain,
        titleTextStyle: TextStyle(
          color: textMain,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: const CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: Color(0xFFECEEF4)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE4E7EF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE4E7EF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primary, width: 1.6),
        ),
      ),
    );
  }
}
