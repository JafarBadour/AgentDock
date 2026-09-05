import 'package:flutter/material.dart';

/// Cursor-like charcoal shell with a violet agent accent.
abstract final class AppColors {
  static const deep = Color(0xFF0F0F10);
  static const mid = Color(0xFF161618);
  static const glow = Color(0xFF2A2438);
  /// Agent / selection accent — Cursor sidebar violet.
  static const accent = Color(0xFFB794F6);
  static const accentSoft = Color(0xFF8B6BC9);
  static const mist = Color(0xFFE8E8EA);
  static const surface = Color(0xFF1C1C1F);
  static const surfaceHigh = Color(0xFF252528);
  static const outline = Color(0xFF3A3A40);

  /// Selected agent row — muted purple pill (matches Cursor agents list).
  static const agentSelected = Color(0xFF2A2440);
  static const agentSelectedBorder = Color(0xFF4A3F6B);

  /// Diff / churn colors (Cursor green / red).
  static const diffAdd = Color(0xFF3FB950);
  static const diffRemove = Color(0xFFF85149);

  /// Chat chrome: user in a soft raised pill; agent bare on the canvas.
  static const bubbleUser = Color(0xFF2A2A2E);
  static const onBubbleUser = Color(0xFFF0F0F2);
  static const chatAgentText = Color(0xFFE8E8EA);
  static const chatMeta = Color(0xFF8B8B93);
  static const chatInlineCodeBg = Color(0xFF2A2A30);
}

/// Dark Material 3 theme tuned for a Cursor-style agent dock.
///
/// Pass [dense] on desktop — Material's default type scale is phone-sized and
/// reads oversized next to Cursor on macOS.
ThemeData buildAppTheme({bool dense = false}) {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.accent,
    onPrimary: AppColors.deep,
    primaryContainer: Color(0xFF3D2F5C),
    onPrimaryContainer: Color(0xFFEDE4FF),
    secondary: AppColors.accentSoft,
    onSecondary: AppColors.mist,
    secondaryContainer: Color(0xFF2E2A3A),
    onSecondaryContainer: Color(0xFFE4DCF5),
    tertiary: Color(0xFF7AA2F7),
    onTertiary: AppColors.deep,
    error: Color(0xFFFF8A80),
    onError: AppColors.deep,
    errorContainer: Color(0xFF5C1F24),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: AppColors.surface,
    onSurface: AppColors.mist,
    onSurfaceVariant: Color(0xFFA0A0A8),
    outline: AppColors.outline,
    outlineVariant: Color(0xFF2E2E34),
    shadow: Colors.black,
    scrim: Colors.black54,
    inverseSurface: AppColors.mist,
    onInverseSurface: AppColors.deep,
    inversePrimary: AppColors.accentSoft,
    surfaceTint: AppColors.accent,
    surfaceContainerLowest: Color(0xFF0C0C0E),
    surfaceContainerLow: Color(0xFF141416),
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: Color(0xFF2C2C30),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
  );
  final textTheme = dense ? _desktopTextTheme(base.textTheme) : base.textTheme;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    visualDensity: dense ? VisualDensity.compact : VisualDensity.standard,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.mist,
      titleTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: AppColors.mist,
      ),
      toolbarHeight: dense ? 44 : kToolbarHeight,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: dense ? 56 : 64,
      backgroundColor: AppColors.surface.withValues(alpha: 0.86),
      indicatorColor: AppColors.accent.withValues(alpha: 0.22),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: dense ? 10 : 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected
              ? AppColors.accent
              : AppColors.mist.withValues(alpha: 0.65),
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected
              ? AppColors.accent
              : AppColors.mist.withValues(alpha: 0.55),
          size: dense ? 20 : 22,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surfaceHigh.withValues(alpha: 0.9),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.outline.withValues(alpha: 0.45)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: AppColors.outline.withValues(alpha: 0.35),
      thickness: 0.5,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh.withValues(alpha: 0.75),
      isDense: dense,
      contentPadding: dense
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
          : null,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(dense ? 10 : 12),
        borderSide: BorderSide(color: AppColors.outline.withValues(alpha: 0.5)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(dense ? 10 : 12),
        borderSide:
            BorderSide(color: AppColors.outline.withValues(alpha: 0.45)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(dense ? 10 : 12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      hintStyle: TextStyle(
        color: AppColors.mist.withValues(alpha: 0.45),
        fontSize: dense ? 12.5 : null,
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.deep,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh.withValues(alpha: 0.96),
      contentTextStyle: TextStyle(
        color: AppColors.mist,
        fontSize: dense ? 12.5 : null,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: AppColors.accentSoft,
      textColor: AppColors.mist,
      tileColor: Colors.transparent,
      dense: dense,
      visualDensity: dense ? VisualDensity.compact : VisualDensity.standard,
    ),
    iconTheme: IconThemeData(
      color: AppColors.accentSoft,
      size: dense ? 18 : 24,
    ),
  );
}

/// Cursor-like desktop type scale (Material defaults are ~2–4px larger).
TextTheme _desktopTextTheme(TextTheme base) {
  TextStyle? scale(TextStyle? s, double size, {double height = 1.35}) =>
      s?.copyWith(fontSize: size, height: height, letterSpacing: 0);

  return base.copyWith(
    displayLarge: scale(base.displayLarge, 28, height: 1.2),
    displayMedium: scale(base.displayMedium, 24, height: 1.2),
    displaySmall: scale(base.displaySmall, 20, height: 1.25),
    headlineLarge: scale(base.headlineLarge, 20, height: 1.25),
    headlineMedium: scale(base.headlineMedium, 17, height: 1.3),
    headlineSmall: scale(base.headlineSmall, 15, height: 1.3),
    titleLarge: scale(base.titleLarge, 14.5, height: 1.3),
    titleMedium: scale(base.titleMedium, 13, height: 1.3),
    titleSmall: scale(base.titleSmall, 12, height: 1.3),
    bodyLarge: scale(base.bodyLarge, 13, height: 1.4),
    bodyMedium: scale(base.bodyMedium, 12.5, height: 1.4),
    bodySmall: scale(base.bodySmall, 11.5, height: 1.35),
    labelLarge: scale(base.labelLarge, 12, height: 1.25),
    labelMedium: scale(base.labelMedium, 11, height: 1.25),
    labelSmall: scale(base.labelSmall, 10.5, height: 1.2),
  );
}
