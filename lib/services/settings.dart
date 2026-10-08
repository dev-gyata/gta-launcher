import 'package:shared_preferences/shared_preferences.dart';

import '../sources/source_selection.dart';

/// Persists source choices, port and play mode between runs.
class Settings {
  Settings(this._prefs);

  static const _mirrorKey = 'mirror_path';
  static const _sourceKindKey = 'source_kind';
  static const _portKey = 'port';
  static const _playInAppKey = 'play_in_app';
  static const defaultPort = 8000;

  final SharedPreferencesAsync _prefs;

  static Settings create() => Settings(SharedPreferencesAsync());

  Future<String?> mirrorPath() => sourceValue(SourceKind.local);
  Future<void> setMirrorPath(String path) =>
      setSourceValue(SourceKind.local, path);

  Future<SourceKind> sourceKind() async {
    final name = await _prefs.getString(_sourceKindKey);
    return SourceKind.values.where((kind) => kind.name == name).firstOrNull ??
        SourceKind.local;
  }

  Future<void> setSourceKind(SourceKind kind) =>
      _prefs.setString(_sourceKindKey, kind.name);

  Future<String?> sourceValue(SourceKind kind) async {
    final value = await _prefs.getString('source_${kind.name}_value');
    return value ??
        (kind == SourceKind.local ? await _prefs.getString(_mirrorKey) : null);
  }

  Future<void> setSourceValue(SourceKind kind, String value) async {
    await _prefs.setString('source_${kind.name}_value', value);
    if (kind == SourceKind.local) await _prefs.setString(_mirrorKey, value);
  }

  Future<int> port() async => await _prefs.getInt(_portKey) ?? defaultPort;
  Future<void> setPort(int port) => _prefs.setInt(_portKey, port);

  Future<bool> playInApp() async => await _prefs.getBool(_playInAppKey) ?? true;
  Future<void> setPlayInApp(bool value) => _prefs.setBool(_playInAppKey, value);
}
