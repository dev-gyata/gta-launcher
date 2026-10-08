import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

/// Shows the locally served game inside the launcher window.
class GamePage extends StatefulWidget {
  const GamePage({super.key, required this.url, required this.onLog, this.environment});

  final Uri url;
  final void Function(String line) onLog;

  /// WebView2 environment (Windows only).
  final WebViewEnvironment? environment;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool? _supported;
  bool _fullScreen = false;

  Future<void> _checkSupport(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: 'self.crossOriginIsolated === true && !!navigator.gpu',
      );
      final supported = result == true;
      widget.onLog(
        supported ? 'Webview: cross-origin isolated, WebGPU available' : 'Webview: missing isolation or WebGPU',
      );
      if (mounted) setState(() => _supported = supported);
    } catch (e) {
      widget.onLog('Webview support check failed: $e');
    }
  }

  Future<void> _toggleFullScreen() async {
    final next = !await windowManager.isFullScreen();
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullScreen = next);
  }

  Future<void> _back() async {
    if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainer,
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  TextButton.icon(onPressed: _back, icon: const Icon(Icons.arrow_back), label: const Text('Launcher')),
                  const Spacer(),
                  if (_loading) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  IconButton(
                    tooltip: 'Reload',
                    onPressed: () => _controller?.reload(),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Open in browser',
                    onPressed: () => launchUrl(widget.url, mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_browser),
                  ),
                  IconButton(
                    tooltip: _fullScreen ? 'Exit full screen' : 'Full screen',
                    onPressed: _toggleFullScreen,
                    icon: Icon(_fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          if (_supported == false)
            MaterialBanner(
              content: const Text(
                "This system's webview can't run the game (needs WebGPU and cross-origin isolation). "
                'Use Open in browser with Chrome or Edge.',
              ),
              actions: [
                TextButton(
                  onPressed: () => launchUrl(widget.url, mode: LaunchMode.externalApplication),
                  child: const Text('Open in browser'),
                ),
              ],
            ),
          Expanded(
            child: InAppWebView(
              webViewEnvironment: widget.environment,
              initialUrlRequest: URLRequest(url: WebUri.uri(widget.url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                iframeAllowFullscreen: true,
                isInspectable: kDebugMode,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStart: (_, _) => setState(() => _loading = true),
              onLoadStop: (controller, _) {
                setState(() => _loading = false);
                _checkSupport(controller);
              },
              onReceivedError: (_, request, error) {
                if (request.isForMainFrame ?? false) widget.onLog('Webview error: ${error.description}');
              },
              onConsoleMessage: (_, message) =>
                  widget.onLog('console.${message.messageLevel.toNativeValue()}: ${message.message}'),
            ),
          ),
        ],
      ),
    );
  }
}
