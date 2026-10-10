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
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)),
          side: BorderSide(color: Color(0xFFECEEF4)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          side: const BorderSide(color: Color(0xFFD7DCE8)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        titleTextStyle: const TextStyle(
          color: textMain,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(
          color: textMain,
          fontSize: 14,
          height: 1.5,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: const BorderSide(color: Color(0xFFE4E7EF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: const BorderSide(color: Color(0xFFE4E7EF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: const BorderSide(color: primary, width: 1.6),
        ),
      ),
    );
  }
}

/// 统一圆角刻度（以工程内主流样式为基准收敛）。
///
/// 语义约定：同类组件在所有页面取同一个值。
/// - [xxs] 进度条 / 细状态条；
/// - [xs] 状态徽章 / 小标签 / 日历格 / 内嵌小元素；
/// - [sm] 输入框 / 内嵌面板 / 选择项 / 图片缩略图；
/// - [md] 按钮 / 列表项 / 分段控件 / 图标块 / 次级容器；
/// - [lg] 卡片容器（含主卡片与渐变卡片）；
/// - [sheet] 底部弹层 / 胶囊标签 / 大圆角块。
class AppRadius {
  /// 进度条 / 细状态条。
  static const double xxs = 4;

  /// 状态徽章 / 小标签 / 日历格 / 内嵌小元素。
  static const double xs = 8;

  /// 输入框 / 内嵌面板 / 选择项 / 图片缩略图。
  static const double sm = 10;

  /// 按钮 / 列表项 / 分段控件 / 图标块 / 次级容器。
  static const double md = 12;

  /// 卡片容器。
  static const double lg = 14;

  /// 底部弹层顶部 / 胶囊标签 / 大圆角块。
  static const double sheet = 20;

  /// 半尺寸圆角（头像、正方形元素等本身应为圆形/半尺寸的场景）：
  /// 集中保留 `size / 2` 的数学表达，避免在各处散写。
  static BorderRadius half(double size) => BorderRadius.circular(size / 2);
}

/// 统一字号阶梯（正文与控件；展示型大数字不在此列）。
class AppFont {
  /// 辅助说明。
  static const double caption = 11;

  /// 标签 / 次要信息。
  static const double tag = 12;

  /// 正文次要。
  static const double body = 13;

  /// 正文。
  static const double bodyLg = 14;

  /// 卡片标题 / 弹层标题。
  static const double title = 16;

  /// 页面标题。
  static const double appBar = 17;
}

/// 统一间距刻度。
class AppSpace {
  /// 4。
  static const double xs = 4;

  /// 8。
  static const double sm = 8;

  /// 12。
  static const double md = 12;

  /// 16。
  static const double lg = 16;

  /// 24。
  static const double xl = 24;
}
