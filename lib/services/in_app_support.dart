import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Whether the game can be shown in an embedded webview on this OS.
///
/// macOS uses WKWebView. Windows uses WebView2, which must be installed (it
/// ships with Windows 10/11). Linux has no supported webview, and Android's
/// WebView is never cross-origin isolated (no shared memory for the game, even
/// with the server's COOP/COEP headers), so both use the browser.
class InAppSupport {
  const InAppSupport._(this.available, this.reason, [this.environment]);

  final bool available;

  /// Why in-app play is unavailable, for the launcher log.
  final String? reason;

  /// WebView2 environment, required by the Windows webview.
  final WebViewEnvironment? environment;

  static Future<InAppSupport> detect() async {
    if (Platform.isMacOS) return const InAppSupport._(true, null);
    if (Platform.isAndroid) {
      return const InAppSupport._(false, "Android's WebView cannot run the game; it opens in Chrome");
    }
    if (Platform.isWindows) {
      try {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (version == null) {
          return const InAppSupport._(false, 'WebView2 Runtime is not installed');
        }
        return InAppSupport._(true, null, await WebViewEnvironment.create());
      } catch (e) {
        return InAppSupport._(false, 'WebView2 failed to start: $e');
      }
    }
    return const InAppSupport._(false, 'In-app play is not supported on this OS');
  }
}
