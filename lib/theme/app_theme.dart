import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ── Shared accent colours ─────────────────────────────────────────────────
  static const Color accentPrimary = Color(0xFF6C63FF);
  static const Color accentSecondary = Color(0xFF00B4D8);
  static const Color accentGlow = Color(0x226C63FF);
  static const Color success = Color(0xFF00C48C);
  static const Color warning = Color(0xFFFFB547);
  static const Color error = Color(0xFFFF5C6B);

  // ── Dark palette ──────────────────────────────────────────────────────────
  static const Color background = Color(0xFF0D0F1A);
  static const Color surface = Color(0xFF161826);
  static const Color surfaceElevated = Color(0xFF1E2136);
  static const Color surfaceBorder = Color(0xFF2A2D45);
  static const Color textPrimary = Color(0xFFE8EAFF);
  static const Color textSecondary = Color(0xFF8B8FA8);
  static const Color textMuted = Color(0xFF4A4D6A);

  // ── Light palette ─────────────────────────────────────────────────────────
  static const Color lightBackground = Color(0xFFF4F5FF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceElevated = Color(0xFFEEEFF8);
  static const Color lightSurfaceBorder = Color(0xFFDDDFF0);
  static const Color lightTextPrimary = Color(0xFF1A1B2E);
  static const Color lightTextSecondary = Color(0xFF5A5C75);
  static const Color lightTextMuted = Color(0xFFA0A3BE);

  // ── Theme getters ─────────────────────────────────────────────────────────
  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        bg: background,
        surf: surface,
        surfEl: surfaceElevated,
        border: surfaceBorder,
        txtPri: textPrimary,
        txtSec: textSecondary,
        txtMut: textMuted,
      );

  static ThemeData get light => _build(
        brightness: Brightness.light,
        bg: lightBackground,
        surf: lightSurface,
        surfEl: lightSurfaceElevated,
        border: lightSurfaceBorder,
        txtPri: lightTextPrimary,
        txtSec: lightTextSecondary,
        txtMut: lightTextMuted,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surf,
    required Color surfEl,
    required Color border,
    required Color txtPri,
    required Color txtSec,
    required Color txtMut,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: accentPrimary,
        onPrimary: Colors.white,
        secondary: accentSecondary,
        onSecondary: Colors.white,
        surface: surf,
        onSurface: txtPri,
        error: error,
        onError: Colors.white,
      ),
      fontFamily: GoogleFonts.poppins().fontFamily,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: txtPri,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: txtPri, fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: surf,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentPrimary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentPrimary,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1),
      iconTheme: IconThemeData(color: txtSec),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surf,
        indicatorColor: accentGlow,
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(color: txtSec, fontSize: 12),
        ),
      ),
      textTheme: GoogleFonts.poppinsTextTheme(TextTheme(
        headlineLarge: TextStyle(color: txtPri, fontSize: 28, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(color: txtPri, fontSize: 22, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: txtPri, fontSize: 18, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: txtPri, fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: txtSec, fontSize: 13, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: txtPri, fontSize: 14),
        bodyMedium: TextStyle(color: txtSec, fontSize: 13),
        bodySmall: TextStyle(color: txtMut, fontSize: 11),
        labelLarge: TextStyle(color: txtPri, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfEl,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accentPrimary, width: 1.5),
        ),
        labelStyle: TextStyle(color: txtSec),
        hintStyle: TextStyle(color: txtMut),
      ),
    );
  }

  // ── Context helpers ───────────────────────────────────────────────────────
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color surfaceOf(BuildContext context) =>
      Theme.of(context).colorScheme.surface;

  static Color borderOf(BuildContext context) =>
      isDark(context) ? surfaceBorder : lightSurfaceBorder;

  static Color bgOf(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor;

  static Color mutedOf(BuildContext context) =>
      isDark(context) ? textMuted : lightTextMuted;

  static Color secondaryOf(BuildContext context) =>
      isDark(context) ? textSecondary : lightTextSecondary;
}
