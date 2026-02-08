import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // --- BACKGROUNDS (Deep Black & Dark Grey) ---
  static const Color background = Color(0xFF000000); // Reines Schwarz
  static const Color surface = Color(0xFF050505);    // Fast Schwarz
  static const Color card = Color(0xFF0A0A0C);       // Sehr dunkles Grau für Cards
  
  // --- MAIN PALETTE (Cyan & Turquoise) ---
  static const Color primary = Color(0xFF00E5FF);    // Electric Cyan (Hauptfarbe)
  static const Color accent = Color(0xFF40E0D0);     // Turquoise (Akzente/Sekundär)
  
  // --- FUNCTIONAL ---
  static const Color warning = Color(0xFFFF0055);    // Cyberpunk Red/Pink für Fehler
  
  // --- TEXT ---
  static const Color textMain = Color(0xFFFFFFFF);   // Reines Weiß
  static const Color textDim = Color(0xFFB0BEC5);    // Kühles Hellgrau/Blaugrau
}

ThemeData buildSciFiTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    primaryColor: AppColors.primary,
    
    // Farbschema Update
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.warning,
      onPrimary: Colors.black, // Text auf Cyan Button muss schwarz sein für Lesbarkeit
      onSecondary: Colors.black,
      onSurface: AppColors.textMain,
    ),
    
    // Text Theme Anpassung
    textTheme: GoogleFonts.rajdhaniTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textMain,
      displayColor: AppColors.primary,
    ),
    
    // Card Theme mit feinem Cyan-Rand
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(
          color: AppColors.primary.withValues(alpha: 0.15), // Subtiler Cyan Rand
          width: 1,
        ),
      ),
    ),
    
    // Icon Theme
    iconTheme: const IconThemeData(
      color: AppColors.primary,
    ),
  );
}