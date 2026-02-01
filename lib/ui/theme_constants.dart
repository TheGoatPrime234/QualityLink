import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const Color background = Color(0xFF020204);
  static const Color surface = Color(0xFF0A0A0C);
  static const Color card = Color(0xFF121214);
  
  static const Color primary = Color(0xFF00FF41);
  static const Color accent = Color(0xFF00E5FF);
  static const Color warning = Color(0xFFFF0055);
  static const Color secondary = Color(0xFFAA00FF);
  
  static const Color textMain = Color(0xFFEEEEEE);
  static const Color textDim = Color(0xFF888899);
}

ThemeData buildSciFiTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    primaryColor: AppColors.primary,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.warning,
    ),
    textTheme: GoogleFonts.rajdhaniTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textMain,
      displayColor: AppColors.primary,
    ),
    // ✅ HIER WAR DER FEHLER: withOpacity statt withValues nutzen
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
      ),
    ),
  );
}