import 'package:flutter/material.dart';

const ink = Color(0xFF101612);
const panel = Color(0xFF1C251E);
const morning = Color(0xFFF3C96B);
const muted = Color(0xFFAAB5A8);
const foreground = Color(0xFFF6F4E9);

class AppPalette {
  const AppPalette({
    required this.ink,
    required this.panel,
    required this.morning,
    required this.muted,
    required this.foreground,
    required this.green,
    required this.blue,
    required this.red,
  });
  final Color ink, panel, morning, muted, foreground, green, blue, red;
  static const dark = AppPalette(
    ink: Color(0xFF101612),
    panel: Color(0xFF1C251E),
    morning: Color(0xFFF3C96B),
    muted: Color(0xFFAAB5A8),
    foreground: Color(0xFFF6F4E9),
    green: Color(0xFF8EDDAB),
    blue: Color(0xFF7FBFFF),
    red: Color(0xFFFFB4AB),
  );
  static const light = AppPalette(
    ink: Color(0xFFF8F6EE),
    panel: Color(0xFFE8EDE3),
    morning: Color(0xFF765600),
    muted: Color(0xFF53614F),
    foreground: Color(0xFF182219),
    green: Color(0xFF28643E),
    blue: Color(0xFF245C93),
    red: Color(0xFF9C3028),
  );
}

extension AppPaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).brightness == Brightness.light
      ? AppPalette.light
      : AppPalette.dark;
}

ThemeData fiveMoreTheme({Brightness brightness = Brightness.dark}) {
  final palette = brightness == Brightness.light
      ? AppPalette.light
      : AppPalette.dark;
  final ink = palette.ink,
      panel = palette.panel,
      morning = palette.morning,
      foreground = palette.foreground,
      muted = palette.muted;
  final scheme = ColorScheme.fromSeed(
    seedColor: morning,
    brightness: brightness,
    surface: ink,
    primary: morning,
    onSurface: foreground,
    onPrimary: ink,
    onSurfaceVariant: muted,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: ink,
    cardColor: panel,
    appBarTheme: AppBarTheme(
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
    dividerColor: foreground.withValues(alpha: .12),
  );
}
