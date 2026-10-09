import 'dart:io';

import 'package:flutter/services.dart';

/// Reading a game data folder picked by the player on Android and iOS.
///
/// Android: permission to read any folder on the device storage by path.
///
/// The Local source reads the game data (about 20 GB, random access) through
/// `dart:io`, which needs real paths. Android's system folder picker only
/// gives content links, so the launcher asks for "All files access" (Android
/// 11+) and lets the player pick the folder in its own browser.
class StorageAccess {
  StorageAccess._();

  static const _channel = MethodChannel('playgta5/storage');

  static Future<bool> has() async =>
      !Platform.isAndroid ||
      (await _channel.invokeMethod<bool>('hasAccess') ?? false);

  /// Opens the system screen (or prompt) and returns whether access was given.
  static Future<bool> request() async =>
      !Platform.isAndroid ||
      (await _channel.invokeMethod<bool>('requestAccess') ?? false);

  /// The device's main storage first, then any removable cards.
  static Future<List<String>> roots() async {
    if (!Platform.isAndroid) return const [];
    return (await _channel.invokeListMethod<String>('storageRoots')) ??
        const [];
  }

  /// Opens Chrome; false when it is not installed.
  static Future<bool> openChrome() async =>
      Platform.isAndroid &&
      (await _channel.invokeMethod<bool>('openChrome') ?? false);

  /// iOS: the system folder picker. The folder stays readable while the app
  /// runs; [bookmark] brings it back after a restart ([resolveIosFolder]).
  static Future<({String path, String? bookmark})?> pickIosFolder() async {
    if (!Platform.isIOS) return null;
    final r = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    if (r == null) return null;
    return (path: r['path'] as String, bookmark: r['bookmark'] as String?);
  }

  /// iOS: a saved bookmark back to a readable folder, with a refreshed
  /// bookmark when the old one went stale; null if the folder is gone.
  static Future<({String path, String? bookmark})?> resolveIosFolder(
    String bookmark,
  ) async {
    if (!Platform.isIOS) return null;
    final r = await _channel.invokeListMethod<Object?>(
      'resolveFolder',
      bookmark,
    );
    if (r == null || r.isEmpty) return null;
    return (
      path: r[0] as String,
      bookmark: r.length > 1 ? r[1] as String? : null,
    );
  }

  /// iOS: `game` in the app's Documents folder, shown in the Files app and in
  /// Finder, where the mirror can be copied without picking anything.
  static Future<String?> iosDocumentsFolder() async =>
      Platform.isIOS ? _channel.invokeMethod<String>('documentsFolder') : null;
}
