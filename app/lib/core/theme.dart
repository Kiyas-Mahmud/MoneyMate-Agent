import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens from the MoneyMate style guide (monochrome + liquid glass).
abstract final class AppColors {
  static const ink = Color(0xFF111111);
  static const surface = Color(0xFFFFFFFF);
  static const canvas = Color(0xFFF4F4F4);
  static const line = Color(0xFFECECEC);
  static const muted = Color(0xFF5C5C5C);
  static const hint = Color(0xFF8A8A8A);

  // Risk signals, used only in small badges and bars
  static const successBg = Color(0xFFE7F4EC);
  static const success = Color(0xFF1E6B41);
  static const warningBg = Color(0xFFFFF3D6);
  static const warning = Color(0xFF8A5300);
  static const dangerBg = Color(0xFFFDECEB);
  static const danger = Color(0xFFA8231A);
}

abstract final class AppRadius {
  static const card = 26.0;
  static const sheet = 34.0;
  static const pill = 999.0;
}

abstract final class AppMotion {
  static const fast = Duration(milliseconds: 250);
  static const base = Duration(milliseconds: 450);
  static const slow = Duration(milliseconds: 600);
  static const spring = Curves.easeOutBack;
  static const smooth = Curves.easeOutCubic;
}

ThemeData buildTheme() {
  final base = ThemeData(useMaterial3: true, colorSchemeSeed: AppColors.ink, brightness: Brightness.light);
  final text = GoogleFonts.interTextTheme(base.textTheme).apply(bodyColor: AppColors.ink, displayColor: AppColors.ink);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.canvas,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.6),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.4),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12, color: AppColors.muted, letterSpacing: 0),
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    inputDecorationTheme: const InputDecorationTheme(
      border: InputBorder.none,
      hintStyle: TextStyle(color: AppColors.hint),
    ),
  );
}
