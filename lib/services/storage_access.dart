import 'dart:io';

import 'package:flutter/services.dart';

/// Android only: permission to read any folder on the device storage by path.
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
}
