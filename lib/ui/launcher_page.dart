import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../server/mirror_server.dart';
import '../server/site_files.dart';
import '../services/in_app_support.dart';
import '../services/mirror_validator.dart';
import '../services/settings.dart';
import 'game_page.dart';

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key, required this.settings, required this.inApp});

  final Settings settings;
  final InAppSupport inApp;

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  final _portController = TextEditingController(text: '${Settings.defaultPort}');
  final _logLines = <String>[];
  final _logScroll = ScrollController();
  late final AppLifecycleListener _lifecycle;

  String? _pickedPath;
  String? _mirrorRoot;
  MirrorServer? _server;
  StreamSubscription<String>? _logSub;
  bool _busy = false;
  bool _playInApp = true;
  String? _error;

  bool get _running => _server?.isRunning ?? false;
  bool get _useInApp => widget.inApp.available && _playInApp;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _server?.dispose();
        return AppExitResponse.exit;
      },
    );
    if (!widget.inApp.available) _appendLog('Playing in the browser: ${widget.inApp.reason}');
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final path = await widget.settings.mirrorPath();
    final port = await widget.settings.port();
    final playInApp = await widget.settings.playInApp();
    if (!mounted) return;
    setState(() {
      _portController.text = '$port';
      _playInApp = playInApp;
      if (path != null) _setPicked(path);
    });
  }

  void _setPicked(String path) {
    _pickedPath = path;
    _mirrorRoot = resolveMirrorRoot(path);
  }

  Future<void> _chooseFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
    if (path == null) return;
    await widget.settings.setMirrorPath(path);
    setState(() => _setPicked(path));
  }

  Future<void> _start() async {
    final root = _mirrorRoot;
    final port = int.tryParse(_portController.text);
    if (root == null) return;
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port must be a number between 1 and 65535.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.settings.setPort(port);
    final site = await loadSiteFiles((name) async => (await rootBundle.load('site/$name')).buffer.asUint8List());
    final server = MirrorServer(root, bundled: site);
    _logSub = server.log.listen(_appendLog);
    try {
      final url = await server.start(port: port);
      _server = server;
      await _play(url);
    } catch (e) {
      await _logSub?.cancel();
      await server.dispose();
      _error = 'Could not start the server: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    await _server?.dispose();
    await _logSub?.cancel();
    _server = null;
    _logSub = null;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _play(Uri url) => _useInApp ? _openInApp(url) : _openBrowser(url);

  Future<void> _openInApp(Uri url) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GamePage(url: url, onLog: _appendLog, environment: widget.inApp.environment),
      ),
    );
  }

  Future<void> _setPlayInApp(bool value) async {
    setState(() => _playInApp = value);
    await widget.settings.setPlayInApp(value);
  }

  Future<void> _openBrowser(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      setState(() => _error = 'Could not open the browser. Visit $url manually.');
    }
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      _logLines.add(line);
      if (_logLines.length > 500) _logLines.removeRange(0, _logLines.length - 500);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _logSub?.cancel();
    _server?.dispose();
    _portController.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = _server?.url;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('playgta5 Launcher', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Pick your mirror folder once, then press Start.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            _FolderRow(
              pickedPath: _pickedPath,
              valid: _mirrorRoot != null,
              enabled: !_running && !_busy,
              onChoose: _chooseFolder,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _portController,
                    enabled: !_running && !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                if (widget.inApp.available) ...[
                  const SizedBox(width: 16),
                  Switch(value: _playInApp, onChanged: _busy ? null : _setPlayInApp),
                  const SizedBox(width: 8),
                  const Text('Play in app'),
                ],
                const Spacer(),
                if (_running) ...[
                  if (widget.inApp.available) ...[
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _openInApp(url!),
                      icon: const Icon(Icons.sports_esports),
                      label: const Text('Play'),
                    ),
                    const SizedBox(width: 12),
                  ],
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _openBrowser(url!),
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Open in browser'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: _busy || _mirrorRoot == null ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _StatusLine(running: _running, url: url, error: _error),
            const SizedBox(height: 4),
            Text(
              _useInApp
                  ? 'The game opens in this window. If it does not run, use Open in browser with Chrome or Edge.'
                  : 'Use Chrome or Edge. The game needs WebGPU.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  controller: _logScroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _logLines.length,
                  itemBuilder: (_, i) =>
                      Text(_logLines[i], style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.pickedPath, required this.valid, required this.enabled, required this.onChoose});

  final String? pickedPath;
  final bool valid;
  final bool enabled;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, hint) = switch ((pickedPath, valid)) {
      (null, _) => (Icons.folder_off_outlined, theme.colorScheme.onSurfaceVariant, 'No mirror folder selected'),
      (_, true) => (Icons.check_circle, Colors.green, 'Mirror found'),
      (_, false) => (Icons.error, theme.colorScheme.error, 'No game.wasm + data/ found in this folder'),
    };
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(pickedPath ?? 'Mirror folder', overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
              Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: color)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(onPressed: enabled ? onChoose : null, child: const Text('Choose…')),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.running, required this.url, required this.error});

  final bool running;
  final Uri? url;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (error != null) {
      return Text(error!, style: TextStyle(color: theme.colorScheme.error));
    }
    return Text(
      running ? 'Running at $url' : 'Stopped',
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}
