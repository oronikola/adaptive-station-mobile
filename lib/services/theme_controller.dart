import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the parent's manually-chosen theme mode (System/Light/Dark)
/// across app restarts. A plain [ValueNotifier] — this app has no
/// state-management package, and [MaterialApp.themeMode] is exactly one
/// value, so a [ValueListenableBuilder] around it is all the wiring needed
/// to make a change here repaint the whole app immediately.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.system);

  static const _prefsKey = 'theme_mode';

  /// Loads the persisted preference, if any — call once before the first
  /// frame (defaults to [ThemeMode.system] until this resolves).
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = switch (prefs.getString(_prefsKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    if (value == mode) return;
    value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }
}
