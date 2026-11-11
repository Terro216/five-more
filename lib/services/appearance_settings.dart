import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppearanceSettings extends ChangeNotifier {
  static final instance = AppearanceSettings();
  ThemeMode mode = ThemeMode.dark;
  bool saving = false;
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    mode = prefs.getString('five_more.theme') == 'light'
        ? ThemeMode.light
        : ThemeMode.dark;
    notifyListeners();
  }

  Future<void> toggle() async {
    if (saving) return;
    saving = true;
    notifyListeners();
    final next = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('five_more.theme', next.name)) {
        throw StateError('Theme was not saved');
      }
      mode = next;
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}
