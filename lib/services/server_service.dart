import 'dart:io';

import 'package:flutter/services.dart';

/// Android only: keeps the app (and its game server) alive while the game
/// plays in Chrome, with a "Game server running · Stop" notification.
///
/// Android freezes or kills an app's background work within about a minute,
/// and the game streams its data from the server the whole time, so a plain
/// background server would stall the game. A foreground service is the
/// supported way to keep it running. It is only used when the game is opened
/// in the browser; in the app's own webview the app is in the foreground.
class ServerService {
  ServerService._();

  static const _channel = MethodChannel('playgta5/server_service');

  /// [onStop] runs when the player taps Stop in the notification.
  static void listen(void Function() onStop) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') onStop();
    });
  }

  static Future<void> start(Uri url) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('start', {'url': '$url'});
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }
}
