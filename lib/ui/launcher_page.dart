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
import '../services/source_manager.dart';
import '../sources/mirror_source.dart';
import '../sources/source_selection.dart';
import 'game_page.dart';

class LauncherPage extends StatefulWidget {
  const LauncherPage({
    super.key,
    required this.settings,
    required this.inApp,
    this.sourceManager = const SourceManager(),
  });

  final Settings settings;
  final InAppSupport inApp;
  final SourceManager sourceManager;

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  final _portController = TextEditingController(
    text: '${Settings.defaultPort}',
  );
  final _sourceController = TextEditingController();
  final _sourceValues = <SourceKind, String>{};
  final _logLines = <String>[];
  final _logScroll = ScrollController();
  late final AppLifecycleListener _lifecycle;

  SourceKind _sourceKind = SourceKind.local;
  String? _pickedPath;
  String? _mirrorRoot;
  MirrorServer? _server;
  StreamSubscription<String>? _logSub;
  SourceCancellation? _cancellation;
  Completer<void>? _startupCleanup;
  Completer<void>? _stopCleanup;
  int _generation = 0;
  bool _loading = true;
  bool _starting = false;
  bool _stopping = false;
  bool _clearingCache = false;
  bool _disposed = false;
  bool _playInApp = true;
  int? _cacheBytes;
  String? _error;

  bool get _running => _server?.isRunning ?? false;
  bool get _busy => _loading || _starting || _stopping || _clearingCache;
  bool get _useInApp => widget.inApp.available && _playInApp;
  bool get _canStart => _sourceKind == SourceKind.local
      ? _mirrorRoot != null
      : _sourceController.text.trim().isNotEmpty;
  bool _active(int generation) =>
      mounted && !_disposed && _generation == generation;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _stop();
        return AppExitResponse.exit;
      },
    );
    if (!widget.inApp.available) {
      _appendLog('Playing in the browser: ${widget.inApp.reason}');
    }
    unawaited(_loadSettings());
    unawaited(_refreshCache());
  }

  Future<void> _loadSettings() async {
    try {
      final kind = await widget.settings.sourceKind();
      for (final source in SourceKind.values) {
        _sourceValues[source] = await widget.settings.sourceValue(source) ?? '';
      }
      final port = await widget.settings.port();
      final playInApp = await widget.settings.playInApp();
      if (!mounted) return;
      setState(() {
        _sourceKind = kind;
        _sourceController.text = _sourceValues[kind] ?? '';
        final path = _sourceValues[SourceKind.local];
        if (path != null && path.isNotEmpty) _setPicked(path);
        _portController.text = '$port';
        _playInApp = playInApp;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load settings: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setPicked(String path) {
    _pickedPath = path;
    _mirrorRoot = resolveMirrorRoot(path);
    _sourceValues[SourceKind.local] = path;
  }

  Future<void> _chooseFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
    if (path == null || !mounted || _busy || _running) return;
    setState(() => _setPicked(path));
    try {
      await widget.settings.setSourceValue(SourceKind.local, path);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save folder: $e');
    }
  }

  Future<void> _selectSource(SourceKind kind) async {
    final previous = _sourceKind;
    final value = previous == SourceKind.local
        ? _pickedPath ?? ''
        : _sourceController.text;
    _sourceValues[previous] = value;
    setState(() {
      _sourceKind = kind;
      _sourceController.text = _sourceValues[kind] ?? '';
      _error = null;
    });
    try {
      await widget.settings.setSourceValue(previous, value);
      await widget.settings.setSourceKind(kind);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save source: $e');
    }
  }

  Future<String?> _chooseRoot(
    List<String> roots,
    SourceCancellation cancellation,
  ) async {
    cancellation.check();
    if (!mounted || _disposed) return null;
    final navigator = Navigator.of(context);
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose a mirror'),
        content: SizedBox(
          width: 480,
          height: (roots.length * 64.0).clamp(64.0, 320.0),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final root in roots)
                ListTile(
                  title: Text(root.isEmpty ? 'Archive root' : root),
                  onTap: () => Navigator.of(context).pop(root),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    try {
      return await Future.any<String?>([
        navigator.push(route),
        cancellation.whenCancelled.then((_) => null),
      ]);
    } finally {
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  Future<void> _start() async {
    if (_busy || _running || !_canStart) return;
    final port = int.tryParse(_portController.text);
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port must be a number between 1 and 65535.');
      return;
    }
    final kind = _sourceKind;
    final value = kind == SourceKind.local
        ? _pickedPath!
        : _sourceController.text.trim();
    final generation = ++_generation;
    final cancellation = SourceCancellation();
    final cleanup = Completer<void>();
    _cancellation = cancellation;
    _startupCleanup = cleanup;
    setState(() {
      _starting = true;
      _error = null;
    });
    MirrorSource? source;
    MirrorServer? server;
    StreamSubscription<String>? subscription;
    Uri? playUrl;
    try {
      await widget.settings.setSourceKind(kind);
      await widget.settings.setSourceValue(kind, value);
      await widget.settings.setPort(port);
      cancellation.check();
      source = await widget.sourceManager.open(
        kind,
        value,
        cancellation: cancellation,
        onLog: (line) {
          if (_active(generation)) _appendLog(line);
        },
        chooseRoot: (roots) => _chooseRoot(roots, cancellation),
      );
      cancellation.check();
      final site = await loadSiteFiles(
        (name) async =>
            (await rootBundle.load('site/$name')).buffer.asUint8List(),
      );
      cancellation.check();
      server = MirrorServer.fromSource(source, bundled: site);
      source = null; // The server owns the source from here.
      subscription = server.log.listen((line) {
        if (_active(generation)) _appendLog(line);
      });
      final url = await server.start(port: port);
      cancellation.check();
      if (!_active(generation)) throw const SourceCancelled();
      _server = server;
      _logSub = subscription;
      server = null;
      subscription = null;
      playUrl = url;
    } catch (e) {
      if (_active(generation) && e is! SourceCancelled) {
        setState(() => _error = 'Could not start the server: $e');
      }
    } finally {
      try {
        await Future.wait<void>([
          if (subscription != null) subscription.cancel(),
          if (server != null) server.dispose(),
          if (source != null) source.dispose(),
        ]);
      } catch (e) {
        _appendLog('Source cleanup failed: $e');
      } finally {
        cleanup.complete();
        if (identical(_startupCleanup, cleanup)) _startupCleanup = null;
        if (mounted) setState(() => _starting = false);
        unawaited(_refreshCache());
      }
    }
    if (playUrl != null && _active(generation) && !cancellation.cancelled) {
      unawaited(_play(playUrl));
    }
  }

  Future<void> _stop() async {
    if (_stopping) {
      await _stopCleanup?.future;
      return;
    }
    final cleanup = Completer<void>();
    _stopCleanup = cleanup;
    _cancellation?.cancel();
    ++_generation;
    final server = _server;
    final subscription = _logSub;
    _server = null;
    _logSub = null;
    if (mounted && !_disposed) setState(() => _stopping = true);
    try {
      await Future.wait<void>([
        if (subscription != null) subscription.cancel(),
        if (server != null) server.dispose(),
        if (_startupCleanup != null) _startupCleanup!.future,
      ]);
    } catch (e) {
      if (mounted && !_disposed) {
        setState(() => _error = 'Could not stop the server: $e');
      }
    } finally {
      cleanup.complete();
      _stopCleanup = null;
      if (mounted && !_disposed) setState(() => _stopping = false);
      unawaited(_refreshCache());
    }
  }

  Future<void> _refreshCache() async {
    try {
      final bytes = await widget.sourceManager.cacheBytes();
      if (mounted && !_disposed) setState(() => _cacheBytes = bytes);
    } catch (e) {
      if (mounted && !_disposed) {
        _appendLog('Could not read torrent cache size: $e');
      }
    }
  }

  Future<void> _clearCache() async {
    if (_busy || _running) return;
    setState(() {
      _clearingCache = true;
      _error = null;
    });
    try {
      await widget.sourceManager.clearCache();
      await _refreshCache();
      _appendLog('Torrent cache cleared');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not clear torrent cache: $e');
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _play(Uri url, {bool? inApp}) async {
    try {
      await ((inApp ?? _useInApp) ? _openInApp(url) : _openBrowser(url));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open the game: $e');
    }
  }

  Future<void> _openInApp(Uri url) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GamePage(
          url: url,
          onLog: _appendLog,
          environment: widget.inApp.environment,
        ),
      ),
    );
  }

  Future<void> _setPlayInApp(bool value) async {
    setState(() => _playInApp = value);
    try {
      await widget.settings.setPlayInApp(value);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save play mode: $e');
    }
  }

  Future<void> _openBrowser(Uri url) async {
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication) &&
          mounted) {
        setState(
          () => _error = 'Could not open the browser. Visit $url manually.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = 'Could not open the browser. Visit $url manually. $e',
        );
      }
    }
  }

  void _appendLog(String line) {
    if (!mounted || _disposed) return;
    setState(() {
      _logLines.add(line);
      if (_logLines.length > 500) {
        _logLines.removeRange(0, _logLines.length - 500);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed && _logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _cancellation?.cancel();
    _lifecycle.dispose();
    unawaited(_logSub?.cancel());
    unawaited(_server?.dispose());
    _portController.dispose();
    _sourceController.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = _server?.url;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: SizedBox(
              height: constraints.maxHeight < 640 ? 640 : constraints.maxHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'playgta5 Launcher',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Choose a game source, then press Start.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<SourceKind>(
                      segments: const [
                        ButtonSegment(
                          value: SourceKind.local,
                          label: Text('Local'),
                          icon: Icon(Icons.folder_outlined),
                        ),
                        ButtonSegment(
                          value: SourceKind.http,
                          label: Text('HTTP'),
                          icon: Icon(Icons.link),
                        ),
                        ButtonSegment(
                          value: SourceKind.magnet,
                          label: Text('Magnet'),
                          icon: Icon(Icons.download_outlined),
                        ),
                      ],
                      selected: {_sourceKind},
                      onSelectionChanged: _busy || _running
                          ? null
                          : (selection) => _selectSource(selection.single),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_sourceKind == SourceKind.local)
                    _FolderRow(
                      pickedPath: _pickedPath,
                      valid: _mirrorRoot != null,
                      enabled: !_running && !_busy,
                      onChoose: _chooseFolder,
                    )
                  else
                    TextField(
                      key: const Key('source-input'),
                      controller: _sourceController,
                      enabled: !_running && !_busy,
                      minLines: 1,
                      maxLines: 3,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: _sourceKind == SourceKind.http
                            ? 'HTTP folder URL'
                            : 'Magnet link',
                        hintText: _sourceKind == SourceKind.http
                            ? 'https://example.com/playgta5.com/'
                            : 'magnet:?xt=urn:btih:…',
                        isDense: true,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Torrent cache: ${_cacheBytes == null ? 'checking…' : _formatBytes(_cacheBytes!)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy || _running ? null : _clearCache,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Clear torrent cache'),
                      ),
                    ],
                  ),
                  Text(
                    'Torrent pieces and prepared ZIP files stay cached until you clear them. No automatic eviction.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: _portController,
                          enabled: !_running && !_busy,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      if (widget.inApp.available)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: _playInApp,
                              onChanged: _busy ? null : _setPlayInApp,
                            ),
                            const Text('Play in app'),
                          ],
                        ),
                      if (_running) ...[
                        if (widget.inApp.available)
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _play(url!, inApp: true),
                            icon: const Icon(Icons.sports_esports),
                            label: const Text('Play'),
                          ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _openBrowser(url!),
                          icon: const Icon(Icons.open_in_browser),
                          label: const Text('Open in browser'),
                        ),
                      ],
                      if (_running || (_starting && !_stopping))
                        FilledButton.tonalIcon(
                          onPressed: _stopping ? null : _stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: _busy || !_canStart ? null : _start,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_starting || _stopping) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      _stopping
                          ? 'Stopping and cleaning up…'
                          : 'Preparing source… compressed ZIP entries may need extraction before play.',
                    ),
                  ] else
                    _StatusLine(running: _running, url: url, error: _error),
                  const SizedBox(height: 4),
                  Text(
                    _useInApp
                        ? 'The game opens in this window. If it does not run, use Open in browser with Chrome or Edge.'
                        : 'Use Chrome or Edge. The game needs WebGPU.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
                        itemBuilder: (_, i) => Text(
                          _logLines[i],
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.pickedPath,
    required this.valid,
    required this.enabled,
    required this.onChoose,
  });

  final String? pickedPath;
  final bool valid;
  final bool enabled;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, hint) = switch ((pickedPath, valid)) {
      (null, _) => (
        Icons.folder_off_outlined,
        theme.colorScheme.onSurfaceVariant,
        'No mirror folder selected',
      ),
      (_, true) => (Icons.check_circle, Colors.green, 'Mirror found'),
      (_, false) => (
        Icons.error,
        theme.colorScheme.error,
        'No game.wasm + data/ found in this folder',
      ),
    };
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pickedPath ?? 'Mirror folder',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: enabled ? onChoose : null,
          child: const Text('Choose…'),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.running,
    required this.url,
    required this.error,
  });

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
