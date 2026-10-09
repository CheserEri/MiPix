import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MiPix 语义色板。
///
/// 所有页面统一通过 [MiPixPalette.of] 取色，不再引用写死的颜色常量，
/// 这样「设置 → 主题模式」在浅色 / 深色之间切换时整站配色会同步翻转。
/// 浅色严格对齐 MIUI 相册，深色沿用同一套设计语言只翻转配色。
@immutable
class MiPixPalette extends ThemeExtension<MiPixPalette> {
  /// 页面底色：Scaffold、顶栏、标签栏。
  final Color background;

  /// 卡片、弹层、对话框、菜单底色。
  final Color surface;

  /// 主文字。
  final Color textPrimary;

  /// 次要文字 / 分组标题 / 弱化图标。
  final Color textSecondary;

  /// 分割线与描边。
  final Color divider;

  /// 强调色（MIUI 蓝）。
  final Color accent;

  /// 缩略图占位 / 输入框填充底色。
  final Color fill;

  /// 当前是否深色。
  final bool isDark;

  const MiPixPalette({
    required this.background,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
    required this.accent,
    required this.fill,
    required this.isDark,
  });

  /// MIUI 相册浅色。
  static const MiPixPalette light = MiPixPalette(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF999999),
    divider: Color(0xFFEDEDED),
    accent: Color(0xFF3482FF),
    fill: Color(0xFFF2F2F2),
    isDark: false,
  );

  /// MIUI 相册深色（OLED 纯黑底 + 轻微抬升的卡片）。
  static const MiPixPalette dark = MiPixPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF1A1A1A),
    textPrimary: Color(0xFFE6E6E6),
    textSecondary: Color(0xFF8A8A8A),
    divider: Color(0xFF2A2A2A),
    accent: Color(0xFF3482FF),
    fill: Color(0xFF1E1E1E),
    isDark: true,
  );

  /// 取当前主题色板。未注册时按 brightness 回退。
  static MiPixPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<MiPixPalette>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  MiPixPalette copyWith({
    Color? background,
    Color? surface,
    Color? textPrimary,
    Color? textSecondary,
    Color? divider,
    Color? accent,
    Color? fill,
    bool? isDark,
  }) {
    return MiPixPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      divider: divider ?? this.divider,
      accent: accent ?? this.accent,
      fill: fill ?? this.fill,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  MiPixPalette lerp(ThemeExtension<MiPixPalette>? other, double t) {
    if (other is! MiPixPalette) return this;
    return MiPixPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      fill: Color.lerp(fill, other.fill, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

class MiPixTheme {
  MiPixTheme._();

  /// MIUI 浅色页面的沉浸式系统栏样式。
  ///
  /// 不要使用 `SystemUiOverlayStyle.dark`：它内建
  /// `systemNavigationBarColor = 0xFF000000`（纯黑），会把底部手势条区域
  /// 涂成黑条，即“小白条黑边”。这里把导航栏设为全透明并关闭系统强制对比度，
  /// 让页面浅色背景自然延伸进手势导航区；状态栏图标保持深色以适配浅底。
  static const SystemUiOverlayStyle lightOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  /// 深色页面的沉浸式系统栏样式：底色全透明，图标转为浅色。
  static const SystemUiOverlayStyle darkOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  /// 按当前主题明暗选择系统栏样式。
  static SystemUiOverlayStyle overlayStyle(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? darkOverlayStyle
          : lightOverlayStyle;

  static ThemeData get lightTheme =>
      _build(MiPixPalette.light, Brightness.light);

  static ThemeData get darkTheme => _build(MiPixPalette.dark, Brightness.dark);

  static ThemeData _build(MiPixPalette p, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = isDark ? const ColorScheme.dark() : const ColorScheme.light();
    final overlay = isDark ? darkOverlayStyle : lightOverlayStyle;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: p.background,
      extensions: <ThemeExtension<dynamic>>[p],
      colorScheme: base.copyWith(
        primary: p.accent,
        onPrimary: Colors.white,
        secondary: p.accent,
        onSecondary: Colors.white,
        surface: p.surface,
        onSurface: p.textPrimary,
        surfaceContainerHighest: p.fill,
        error: const Color(0xFFF87171),
        onError: Colors.white,
      ),
      // AppBar：透明 + 沉浸
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: p.textPrimary),
        systemOverlayStyle: overlay,
      ),
      // 卡片：大圆角 + 极淡阴影
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        margin: EdgeInsets.zero,
      ),
      // 底部 sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      // 对话框：底色与文字都取自色板。
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
        contentTextStyle: TextStyle(
          fontSize: 14,
          color: p.textPrimary,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
      ),
      // 右上角「⋮」弹出菜单：跟随色板，避免 M3 默认取色与整体风格冲突。
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        // M3 下菜单项文字取 labelTextStyle，textStyle 仅作 M2 回退。
        labelTextStyle: WidgetStatePropertyAll<TextStyle?>(
          TextStyle(fontSize: 15, color: p.textPrimary),
        ),
        textStyle: TextStyle(fontSize: 15, color: p.textPrimary),
      ),
      // 文字主题
      textTheme: TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: p.textPrimary,
          letterSpacing: -1,
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: p.textPrimary,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: p.textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: p.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: p.textSecondary,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: p.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
      // 按钮
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent.withValues(alpha: 0.2),
          foregroundColor: p.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      // IconButton
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: p.textPrimary,
        ),
      ),
      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: p.fill,
        selectedColor: p.accent.withValues(alpha: 0.3),
        labelStyle: TextStyle(color: p.textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        side: BorderSide.none,
      ),
      // 分割线
      dividerTheme: DividerThemeData(
        color: p.divider,
        thickness: 1,
        space: 1,
      ),
      // SnackBar：两种模式都用深色浮层 + 浅色文字，与 MIUI 一致。
      snackBarTheme: SnackBarThemeData(
        backgroundColor:
            isDark ? const Color(0xFF2A2A2A) : const Color(0xFF323232),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        contentTextStyle: const TextStyle(color: Colors.white),
      ),
    );
  }
}
