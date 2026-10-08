import 'package:shared_preferences/shared_preferences.dart';
import 'package:playgta5_launcher/services/in_app_support.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class MemoryPreferences implements SharedPreferencesAsync {
  final values = <String, Object>{};
  @override
  Future<String?> getString(String key) async => values[key] as String?;
  @override
  Future<int?> getInt(String key) async => values[key] as int?;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BrowserSupport implements InAppSupport {
  @override
  bool get available => false;
  @override
  String? get reason => 'test browser';
  @override
  WebViewEnvironment? get environment => null;
}
