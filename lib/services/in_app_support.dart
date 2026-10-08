import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Whether the game can be shown in an embedded webview on this OS.
///
/// macOS uses WKWebView. Windows uses WebView2, which must be installed (it
/// ships with Windows 10/11). Linux has no supported webview, so it always
/// falls back to the system browser.
class InAppSupport {
  const InAppSupport._(this.available, this.reason, [this.environment]);

  final bool available;

  /// Why in-app play is unavailable, for the launcher log.
  final String? reason;

  /// WebView2 environment, required by the Windows webview.
  final WebViewEnvironment? environment;

  static Future<InAppSupport> detect() async {
    if (Platform.isMacOS) return const InAppSupport._(true, null);
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
