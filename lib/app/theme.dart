import 'package:flutter/material.dart';

const ink = Color(0xFF101612);
const panel = Color(0xFF1C251E);
const morning = Color(0xFFF3C96B);
const muted = Color(0xFFAAB5A8);
const foreground = Color(0xFFF6F4E9);

ThemeData fiveMoreTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: morning,
    brightness: Brightness.dark,
    surface: ink,
    primary: morning,
    onSurface: foreground,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: ink,
    cardColor: panel,
    appBarTheme: const AppBarTheme(
      backgroundColor: ink,
      foregroundColor: foreground,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ink,
      indicatorColor: morning.withValues(alpha: .17),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected) ? morning : muted,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 54),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panel,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF334335),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerColor: Colors.white.withValues(alpha: .08),
  );
}
