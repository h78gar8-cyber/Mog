import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF16171A);
  static const surface = Color(0xFF212226);
  static const surfaceElevated = Color(0xFF2A2B30);
  static const accent = Color(0xFF5B8DEF);
  static const accentSoft = Color(0xFF3A6EA5);
  static const textPrimary = Color(0xFFE7E8EC);
  static const textSecondary = Color(0xFF9A9BA1);
  static const divider = Color(0xFF101113);
  static const warning = Color(0xFFF2A154);
}

class AppTheme {
  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
      ),
      iconTheme: const IconThemeData(color: AppColors.textPrimary, size: 22),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.accent,
        inactiveTrackColor: AppColors.surfaceElevated,
        thumbColor: AppColors.accent,
        overlayColor: AppColors.accent.withValues(alpha: 0.15),
        trackHeight: 3,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.surfaceElevated,
          foregroundColor: AppColors.textPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      splashFactory: NoSplash.splashFactory, // إحساس أنعم يشبه CapCut بدل تموّج Material الافتراضي
    );
  }
}
