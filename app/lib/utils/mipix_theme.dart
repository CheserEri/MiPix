import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MiPix Design System — 玻璃拟态 + OLED 深色沉浸
class MiPixColors {
  MiPixColors._();

  /// OLED 纯黑背景
  static const Color background = Color(0xFF000000);

  /// 极深蓝灰，用于卡片/浮层
  static const Color surface = Color(0xFF0F172A);

  /// 玻璃拟态背景（带透明度）
  static const Color glass = Color(0x1AFFFFFF);

  /// 主文字：90% 白
  static const Color textPrimary = Color(0xE6FFFFFF);

  /// 次要文字：60% 白
  static const Color textSecondary = Color(0x99FFFFFF);

  /// 禁用文字：38% 白
  static const Color textDisabled = Color(0x61FFFFFF);

  /// 品牌强调色：石板蓝
  static const Color accent = Color(0xFF94A3B8);

  /// 状态色
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color error = Color(0xFFF87171);
  static const Color info = Color(0xFF60A5FA);

  // ---- MIUI 相册风格（浅色）----
  // 照片页 / 相册页与小米相册保持一致的视觉参数。

  /// 页面背景：纯白
  static const Color miuiBackground = Color(0xFFFFFFFF);

  /// 主文字：近黑
  static const Color miuiText = Color(0xFF1A1A1A);

  /// 分组标题 / 次要文字：灰
  static const Color miuiSubText = Color(0xFF999999);

  /// 分割线：极浅灰
  static const Color miuiDivider = Color(0xFFEDEDED);

  /// 可点击强调色：MIUI 蓝
  static const Color miuiBlue = Color(0xFF3482FF);

  /// 缩略图占位底色
  static const Color miuiGridFill = Color(0xFFF2F2F2);
}

class MiPixTheme {
  MiPixTheme._();

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: MiPixColors.background,
      colorScheme: const ColorScheme.dark(
        primary: MiPixColors.accent,
        onPrimary: MiPixColors.background,
        secondary: MiPixColors.accent,
        onSecondary: MiPixColors.background,
        surface: MiPixColors.surface,
        onSurface: MiPixColors.textPrimary,
        error: MiPixColors.error,
        onError: Colors.white,
        surfaceContainerHighest: MiPixColors.glass,
      ),
      // AppBar：透明 + 沉浸
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: MiPixColors.textPrimary,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: MiPixColors.textPrimary),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      ),
      // 卡片：大圆角 + 极淡阴影
      cardTheme: CardThemeData(
        color: MiPixColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        margin: EdgeInsets.zero,
      ),
      // 底部 sheet
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: MiPixColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      // 对话框
      dialogTheme: const DialogThemeData(
        backgroundColor: MiPixColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
      ),
      // 文字主题
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: MiPixColors.textPrimary,
          letterSpacing: -1,
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: MiPixColors.textPrimary,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: MiPixColors.textPrimary,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: MiPixColors.textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: MiPixColors.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: MiPixColors.textSecondary,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: MiPixColors.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
      // 按钮
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: MiPixColors.accent.withValues(alpha: 0.2),
          foregroundColor: MiPixColors.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      // IconButton
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: MiPixColors.textPrimary,
        ),
      ),
      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: MiPixColors.glass,
        selectedColor: MiPixColors.accent.withValues(alpha: 0.3),
        labelStyle: const TextStyle(color: MiPixColors.textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        side: BorderSide.none,
      ),
      // 分割线：极淡
      dividerTheme: const DividerThemeData(
        color: Color(0x0DFFFFFF),
        thickness: 1,
        space: 1,
      ),
      // SnackBar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: MiPixColors.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        contentTextStyle: const TextStyle(color: MiPixColors.textPrimary),
      ),
    );
  }
}
