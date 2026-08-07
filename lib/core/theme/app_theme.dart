import 'package:flutter/material.dart';

class AppColors {
  // Sentiment — same in both themes
  static const primary = Color(0xFFF7931A);
  static const onPrimary = Color(0xFF000000);
  static const positive = Color(0xFF00C896);
  static const negative = Color(0xFFFF4757);

  /// Privacy / health score colour: green ≥80, amber ≥60, orange ≥40, red <40.
  static Color scoreColor(int score) {
    if (score >= 80) return positive;
    if (score >= 60) return Colors.amber.shade600;
    if (score >= 40) return Colors.orange;
    return negative;
  }

  /// Privacy / health score letter grade.
  static String scoreLetter(int score) {
    if (score >= 90) return 'A+';
    if (score >= 80) return 'A';
    if (score >= 70) return 'B';
    if (score >= 60) return 'C';
    if (score >= 50) return 'D';
    return 'F';
  }
}

class DarkColors {
  static const background = Color(0xFF0A0A0F);
  static const surface = Color(0xFF13131A);
  static const surfaceVariant = Color(0xFF1C1C27);
  static const border = Color(0xFF252535);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF8888AA);
  static const textMuted = Color(0xFF555570);
}

class LightColors {
  static const background = Color(0xFFF5F5F7);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceVariant = Color(0xFFEEEEF4);
  static const border = Color(0xFFDDDDE8);
  static const textPrimary = Color(0xFF1A1A2E);
  static const textSecondary = Color(0xFF666688);
  static const textMuted = Color(0xFFAAAAAA);
}

class AppTheme {
  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        scaffoldBg: DarkColors.background,
        surface: DarkColors.surface,
        surfaceVariant: DarkColors.surfaceVariant,
        border: DarkColors.border,
        textPrimary: DarkColors.textPrimary,
        textSecondary: DarkColors.textSecondary,
        textMuted: DarkColors.textMuted,
      );

  static ThemeData get light => _build(
        brightness: Brightness.light,
        scaffoldBg: LightColors.background,
        surface: LightColors.surface,
        surfaceVariant: LightColors.surfaceVariant,
        border: LightColors.border,
        textPrimary: LightColors.textPrimary,
        textSecondary: LightColors.textSecondary,
        textMuted: LightColors.textMuted,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color scaffoldBg,
    required Color surface,
    required Color surfaceVariant,
    required Color border,
    required Color textPrimary,
    required Color textSecondary,
    required Color textMuted,
  }) =>
      ThemeData(
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: scaffoldBg,
        colorScheme: ColorScheme(
          brightness: brightness,
          surface: surface,
          onSurface: textPrimary,
          primary: AppColors.primary,
          onPrimary: AppColors.onPrimary,
          secondary: textSecondary,
          onSecondary: textPrimary,
          error: AppColors.negative,
          onError: Colors.white,
          outline: border,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: scaffoldBg,
          foregroundColor: textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: border),
          ),
        ),
        dividerTheme: DividerThemeData(color: border, thickness: 1),
        textTheme: TextTheme(
          displayLarge: TextStyle(
            color: textPrimary,
            fontSize: 42,
            fontWeight: FontWeight.w300,
            letterSpacing: -1,
          ),
          displayMedium: TextStyle(
            color: textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w300,
            letterSpacing: -0.5,
          ),
          titleMedium: TextStyle(
            color: textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.2,
          ),
          bodyLarge: TextStyle(color: textPrimary, fontSize: 16),
          bodyMedium: TextStyle(color: textSecondary, fontSize: 14),
          bodySmall: TextStyle(color: textMuted, fontSize: 12),
          labelLarge: const TextStyle(
            color: AppColors.primary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceVariant,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
          hintStyle: TextStyle(color: textMuted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.onPrimary,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        iconTheme: IconThemeData(color: textSecondary, size: 20),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: surfaceVariant,
          contentTextStyle: TextStyle(color: textPrimary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          behavior: SnackBarBehavior.floating,
        ),
      );
}
