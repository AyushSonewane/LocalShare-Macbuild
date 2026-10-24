import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kThemeKey = 'theme_mode';
const _kSavePathKey = 'save_path';
const _kDeviceNameKey = 'device_name';
const _kFunNameKey = 'device_fun_name';
const _kOnboardingKey = 'onboarding_seen';
const _kSaveToGalleryKey = 'save_to_gallery';

class SettingsService extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;
  String? _customSavePath;
  String _deviceName = '';
  String _funName = '';
  bool _hasSeenOnboarding = false;
  bool _saveToGallery = false;

  ThemeMode get themeMode => _themeMode;
  String? get customSavePath => _customSavePath;
  bool get hasSeenOnboarding => _hasSeenOnboarding;
  bool get saveToGallery => _saveToGallery;

  /// Returns the user-set device name, or the generated fun name as fallback.
  String get deviceName => _deviceName.isNotEmpty ? _deviceName : _funName;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kThemeKey) ?? 'dark';
    _themeMode = raw == 'light' ? ThemeMode.light : ThemeMode.dark;
    _customSavePath = prefs.getString(_kSavePathKey);
    _deviceName = prefs.getString(_kDeviceNameKey) ?? '';
    _funName = prefs.getString(_kFunNameKey) ?? '';
    _hasSeenOnboarding = prefs.getBool(_kOnboardingKey) ?? false;
    _saveToGallery = prefs.getBool(_kSaveToGalleryKey) ?? false;
    notifyListeners();
  }

  Future<void> markOnboardingSeen() async {
    _hasSeenOnboarding = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnboardingKey, true);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kThemeKey, mode == ThemeMode.light ? 'light' : 'dark');
    notifyListeners();
  }

  Future<void> setSavePath(String path) async {
    _customSavePath = path;
    notifyListeners(); // update UI immediately
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSavePathKey, path);
  }

  Future<void> resetSavePath() async {
    _customSavePath = null;
    notifyListeners(); // update UI immediately
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSavePathKey);
  }

  Future<void> setDeviceName(String name) async {
    _deviceName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_deviceName.isEmpty) {
      await prefs.remove(_kDeviceNameKey);
    } else {
      await prefs.setString(_kDeviceNameKey, _deviceName);
    }
    notifyListeners();
  }

  Future<void> setSaveToGallery(bool value) async {
    _saveToGallery = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSaveToGalleryKey, value);
  }

  /// Returns the effective save directory (custom or default).
  Future<Directory> effectiveSaveDirectory() async {
    // Use the custom path if set and the directory exists.
    // On Android we now store real paths (e.g. /storage/emulated/0/Download/LocalShare)
    // so this works correctly on all platforms.
    if (_customSavePath != null) {
      try {
        final dir = Directory(_customSavePath!);
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      } catch (_) {
        // Custom path failed — fall through to default.
      }
    }
    // Default: public Downloads/LocalShare on Android (visible to all apps).
    if (Platform.isAndroid) {
      try {
        final dl = Directory('/storage/emulated/0/Download/LocalShare');
        if (!await dl.exists()) await dl.create(recursive: true);
        return dl;
      } catch (_) {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return ext;
      }
    }
    // Default on Windows: C:\Users\<username>\Downloads\LocalShare
    if (Platform.isWindows) {
      try {
        final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOMEPATH'] ?? '';
        if (home.isNotEmpty) {
          final dl = Directory('$home\\Downloads\\LocalShare');
          if (!await dl.exists()) await dl.create(recursive: true);
          return dl;
        }
      } catch (_) {
        // Fall through to documents directory.
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
        '${docs.path}${Platform.pathSeparator}LocalShare${Platform.pathSeparator}received');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

