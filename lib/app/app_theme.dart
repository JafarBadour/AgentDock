import 'package:flutter/material.dart';

/// Deep ocean palette for Agent Dock.
abstract final class AppColors {
  static const deep = Color(0xFF060E1A);
  static const mid = Color(0xFF0C1F3A);
  static const glow = Color(0xFF1A4A7A);
  static const accent = Color(0xFF5EB3FF);
  static const accentSoft = Color(0xFF3D7EB8);
  static const mist = Color(0xFFB8D4F0);
  static const surface = Color(0xFF122236);
  static const surfaceHigh = Color(0xFF1A2F4A);
  static const outline = Color(0xFF2E4A6E);

  /// Cursor-style chat chrome: user in a soft raised pill; agent bare on the canvas.
  static const bubbleUser = Color(0xFF243447);
  static const onBubbleUser = Color(0xFFE8F1FA);
  static const chatAgentText = Color(0xFFE6EEF8);
  static const chatMeta = Color(0xFF8FA6BF);
  static const chatInlineCodeBg = Color(0xFF1C2B3D);
}

/// Dark blue Material 3 theme tuned for a translucent shell over waves.
ThemeData buildAppTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.accent,
    onPrimary: AppColors.deep,
    primaryContainer: Color(0xFF1E3F66),
    onPrimaryContainer: AppColors.mist,
    secondary: AppColors.accentSoft,
    onSecondary: AppColors.mist,
    secondaryContainer: Color(0xFF243D5C),
    onSecondaryContainer: Color(0xFFD0E4F8),
    tertiary: Color(0xFF7AA8D4),
    onTertiary: AppColors.deep,
    error: Color(0xFFFF8A80),
    onError: AppColors.deep,
    errorContainer: Color(0xFF5C1F24),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: AppColors.surface,
    onSurface: AppColors.mist,
    onSurfaceVariant: Color(0xFF94AEC9),
    outline: AppColors.outline,
    outlineVariant: Color(0xFF243650),
    shadow: Colors.black,
    scrim: Colors.black54,
    inverseSurface: AppColors.mist,
    onInverseSurface: AppColors.deep,
    inversePrimary: AppColors.accentSoft,
    surfaceTint: AppColors.accent,
    surfaceContainerLowest: Color(0xFF080F18),
    surfaceContainerLow: Color(0xFF0E1928),
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: Color(0xFF223A58),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.mist,
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      height: 64,
      backgroundColor: AppColors.surface.withValues(alpha: 0.72),
      indicatorColor: AppColors.accent.withValues(alpha: 0.22),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? AppColors.accent : AppColors.mist.withValues(alpha: 0.65),
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? AppColors.accent : AppColors.mist.withValues(alpha: 0.55),
          size: 22,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surfaceHigh.withValues(alpha: 0.82),
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
      fillColor: AppColors.surfaceHigh.withValues(alpha: 0.65),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.outline.withValues(alpha: 0.5)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.outline.withValues(alpha: 0.45)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      hintStyle: TextStyle(color: AppColors.mist.withValues(alpha: 0.45)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.deep,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh.withValues(alpha: 0.95),
      contentTextStyle: const TextStyle(color: AppColors.mist),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: AppColors.accentSoft,
      textColor: AppColors.mist,
      tileColor: Colors.transparent,
    ),
    iconTheme: const IconThemeData(color: AppColors.accentSoft),
  );
}
