import 'package:shared_preferences/shared_preferences.dart';

/// Persists the launcher's mirror folder, port and play mode between runs.
class Settings {
  Settings(this._prefs);

  static const _mirrorKey = 'mirror_path';
  static const _portKey = 'port';
  static const _playInAppKey = 'play_in_app';
  static const defaultPort = 8000;

  final SharedPreferencesAsync _prefs;

  static Settings create() => Settings(SharedPreferencesAsync());

  Future<String?> mirrorPath() => _prefs.getString(_mirrorKey);
  Future<void> setMirrorPath(String path) => _prefs.setString(_mirrorKey, path);

  Future<int> port() async => await _prefs.getInt(_portKey) ?? defaultPort;
  Future<void> setPort(int port) => _prefs.setInt(_portKey, port);

  Future<bool> playInApp() async => await _prefs.getBool(_playInAppKey) ?? true;
  Future<void> setPlayInApp(bool value) => _prefs.setBool(_playInAppKey, value);
}
