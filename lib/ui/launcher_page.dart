import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:torrent_engine/torrent_engine.dart';
import 'package:url_launcher/url_launcher.dart';

import '../server/mirror_server.dart';
import '../server/site_files.dart';
import '../services/device.dart';
import '../services/game_options.dart';
import '../services/in_app_support.dart';
import '../services/mirror_validator.dart';
import '../services/server_service.dart';
import '../services/settings.dart';
import '../services/source_manager.dart';
import '../services/storage_access.dart';
import '../sources/mirror_source.dart';
import '../sources/source_selection.dart';
import 'folder_browser.dart';
import 'game_options_dialog.dart';
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
  GameOptions _gameOptions = GameOptions.platformDefaults;
  int? _cacheBytes;
  String? _error;

  /// Phones and tablets: stops the server once the app has been in the
  /// background this long (the player left the game without quitting).
  static const _backgroundLimit = Duration(minutes: 5);

  /// Phones and tablets, game in the browser: stops the server once the game
  /// page has sent nothing (not even its 30 s heartbeat) for this long.
  static const _idleLimit = Duration(minutes: 5);
  Timer? _backgroundStop;
  Timer? _idleCheck;

  bool get _running => _server?.isRunning ?? false;
  bool get _busy => _loading || _starting || _stopping || _clearingCache;
  // iOS always plays in the app: it suspends an app in the background, so a
  // game in Safari would lose its server.
  bool get _useInApp =>
      widget.inApp.available && (_playInApp || Platform.isIOS);
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
      // Phones and tablets never ask to exit: the app closes or is put away.
      onDetach: isMobile ? () => unawaited(_stop()) : null,
      onHide: isMobile ? _onHide : null,
      onShow: isMobile ? _onShow : null,
    );
    ServerService.listen(() {
      _appendLog('Stop pressed in the notification');
      unawaited(_stop());
    });
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
      final gameOptions = await widget.settings.gameOptions();
      if (!mounted) return;
      setState(() {
        _sourceKind = kind == SourceKind.magnet && !TorrentEngine.isSupported
            ? SourceKind.local
            : kind;
        _sourceController.text = _sourceValues[_sourceKind] ?? '';
        final path = _sourceValues[SourceKind.local];
        if (path != null && path.isNotEmpty) _setPicked(path);
        _portController.text = '$port';
        _playInApp = playInApp;
        _gameOptions = gameOptions;
      });
      if (Platform.isIOS) await _restoreIosFolder();
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

  /// The app's own folder on the device storage: readable without any
  /// permission, used when "All files access" is refused (the game data is
  /// copied there over USB or with `adb push`).
  Future<String?> _androidGameFolder() async {
    final base = await getExternalStorageDirectory();
    if (base == null) return null;
    final dir = Directory('${base.path}${Platform.pathSeparator}game');
    await dir.create(recursive: true);
    return dir.path;
  }

  /// Android: the system folder picker gives no file path, so the launcher
  /// asks for "All files access" and offers its own folder browser; without
  /// the permission it falls back to the app's own folder.
  Future<String?> _chooseAndroidFolder() async {
    if (!await StorageAccess.has()) {
      if (!mounted) return null;
      final allow = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow access to your files'),
          content: const Text(
            'To use game data from any folder on this device, allow "All files access" for playgta5 Launcher on the next screen. '
            'It only reads the folder you choose. Without it, the launcher can only use its own folder.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Use app folder'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (allow == null) return null;
      if (!allow || !await StorageAccess.request()) {
        final path = await _androidGameFolder();
        if (path != null && resolveMirrorRoot(path) == null) {
          _appendLog(
            'Copy the playgta5.com folder into $path (over USB, or adb push), then press Choose… again.',
          );
        }
        return path;
      }
    }
    final roots = await StorageAccess.roots();
    if (roots.isEmpty || !mounted) return null;
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FolderBrowser(
          roots: roots,
          // Start where the last pick was, unless that was the app's own
          // fallback folder: then at the top of the storage.
          initial: _pickedPath?.contains('/Android/data/') ?? true
              ? null
              : _pickedPath,
        ),
      ),
    );
  }

  /// iOS: a folder picked earlier is only readable again through its saved
  /// bookmark; without one, the app's Documents `game` folder (filled from
  /// the Files app or Finder) is the default.
  Future<void> _restoreIosFolder() async {
    try {
      final bookmark = await widget.settings.localBookmark();
      final restored = bookmark == null
          ? null
          : await StorageAccess.resolveIosFolder(bookmark);
      if (restored?.bookmark != null) {
        await widget.settings.setLocalBookmark(restored!.bookmark);
      }
      final path = restored?.path ?? await StorageAccess.iosDocumentsFolder();
      if (path == null || !mounted) return;
      setState(() => _setPicked(path));
      if (restored == null && _mirrorRoot == null) {
        _appendLog(
          'Copy the playgta5.com folder into On My iPad/iPhone > playgta5 Launcher > game (Files app, or Finder over USB), '
          'or press Choose… to pick a folder.',
        );
      }
    } catch (e) {
      _appendLog('Could not restore the mirror folder: $e');
    }
  }

  Future<void> _chooseFolder() async {
    if (Platform.isIOS) {
      final picked = await StorageAccess.pickIosFolder();
      if (picked == null || !mounted || _busy || _running) return;
      setState(() => _setPicked(picked.path));
      try {
        await widget.settings.setSourceValue(SourceKind.local, picked.path);
        await widget.settings.setLocalBookmark(picked.bookmark);
      } catch (e) {
        if (mounted) setState(() => _error = 'Could not save folder: $e');
      }
      return;
    }
    if (Platform.isAndroid) {
      final path = await _chooseAndroidFolder();
      if (path == null || !mounted || _busy || _running) return;
      setState(() => _setPicked(path));
      try {
        await widget.settings.setSourceValue(SourceKind.local, path);
      } catch (e) {
        if (mounted) setState(() => _error = 'Could not save folder: $e');
      }
      return;
    }
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
    _backgroundStop?.cancel();
    _backgroundStop = null;
    _idleCheck?.cancel();
    _idleCheck = null;
    unawaited(
      ServerService.stop().catchError(
        (Object e) => _appendLog('Could not stop the notification: $e'),
      ),
    );
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

  Future<void> _editGameOptions() async {
    final options = await showDialog<GameOptions>(
      context: context,
      builder: (_) => GameOptionsDialog(initial: _gameOptions),
    );
    if (options == null || !mounted) return;
    setState(() => _gameOptions = options);
    try {
      await widget.settings.setGameOptions(options);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save game options: $e');
    }
  }

  Future<void> _openInApp(Uri url) async {
    url = _gameOptions.apply(url);
    final toBrowser = await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => GamePage(
          url: url,
          onLog: _appendLog,
          environment: widget.inApp.environment,
        ),
      ),
    );
    if (!isMobile) return;
    // Phones and tablets: leaving the game ends it, so the server stops with
    // it, unless the player moved the game to the browser.
    if (toBrowser == true) {
      await _openBrowser(url);
    } else {
      await _stop();
    }
  }

  /// Chrome hides WebGPU on graphics chips it has not approved (the page
  /// then reports "no usable graphics adapter"); its "Unsafe WebGPU Support"
  /// flag lifts that. Apps cannot open chrome:// pages, so this copies the
  /// flag's address and opens Chrome for the player to paste it.
  Future<void> _enableWebGpuHelp() async {
    const flag = 'chrome://flags/#enable-unsafe-webgpu';
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn on WebGPU in Chrome'),
        content: const Text(
          'If the game says WebGPU found no usable graphics adapter, Chrome may be hiding WebGPU on this device.\n\n'
          '1. Tap Copy and open Chrome.\n'
          '2. Paste into the address bar and go.\n'
          '3. Set "Unsafe WebGPU Support" to Enabled, then tap Relaunch.\n\n'
          'This setting is experimental: Chrome may be less stable with it, and it does not add missing hardware '
          'features (the game also needs BC texture support).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Copy and open Chrome'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await Clipboard.setData(const ClipboardData(text: flag));
    _appendLog('Copied $flag: paste it into Chrome\'s address bar');
    if (!await StorageAccess.openChrome() && mounted) {
      setState(
        () => _error = 'Chrome is not installed. Install it, then open $flag',
      );
    }
  }

  void _onHide() {
    // The browser keeps the server busy while the app is in the background;
    // the idle check covers that case.
    if (!_running || _idleCheck != null) return;
    _backgroundStop?.cancel();
    _backgroundStop = Timer(_backgroundLimit, () {
      _appendLog('Stopped the server after 5 minutes in the background');
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      unawaited(_stop());
    });
  }

  void _onShow() {
    _backgroundStop?.cancel();
    _backgroundStop = null;
  }

  /// Phones and tablets, game in the browser: a foreground service keeps the
  /// app alive (Android would otherwise freeze the server within a minute),
  /// and the server stops once the game page has gone quiet.
  Future<void> _watchBrowserGame(Uri url) async {
    if (!isMobile || _idleCheck != null) return;
    // Chrome coming up hid this app, possibly before this ran: the browser
    // game is not "left in the background".
    _backgroundStop?.cancel();
    _backgroundStop = null;
    try {
      await ServerService.start(url);
    } catch (e) {
      _appendLog('Could not start the server notification: $e');
    }
    _idleCheck = Timer.periodic(const Duration(seconds: 30), (_) {
      final last = _server?.lastRequest;
      if (last != null && DateTime.now().difference(last) < _idleLimit) return;
      _appendLog(
        'The game page has been quiet for 5 minutes: stopping the server',
      );
      unawaited(_stop());
    });
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
    url = _gameOptions.apply(url);
    try {
      // Phones and tablets: the server's keep-alive service (and its
      // notification permission prompt) comes first, then the browser.
      await _watchBrowserGame(url);
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
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
    _backgroundStop?.cancel();
    _idleCheck?.cancel();
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
      // SafeArea: on phones the layout would otherwise run under the status bar.
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: SizedBox(
                height: constraints.maxHeight < 640
                    ? 640
                    : constraints.maxHeight,
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
                        segments: [
                          const ButtonSegment(
                            value: SourceKind.local,
                            label: Text('Local'),
                            icon: Icon(Icons.folder_outlined),
                          ),
                          const ButtonSegment(
                            value: SourceKind.http,
                            label: Text('HTTP'),
                            icon: Icon(Icons.link),
                          ),
                          // Torrents need the native engine, which is desktop only.
                          if (TorrentEngine.isSupported)
                            const ButtonSegment(
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
                    if (TorrentEngine.isSupported) ...[
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
                    ] else
                      Text(
                        'The game data is about 20 GB: make sure the device has room for it.',
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
                        OutlinedButton.icon(
                          key: const Key('game-options'),
                          onPressed: _busy ? null : _editGameOptions,
                          icon: const Icon(Icons.tune),
                          label: Text(
                            _gameOptions.changedCount == 0
                                ? 'Game options'
                                : 'Game options (${_gameOptions.changedCount} set)',
                          ),
                        ),
                        if (widget.inApp.available && !Platform.isIOS)
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
                          if (!Platform.isIOS)
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _openBrowser(url!),
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
                          ? Platform.isIOS
                                ? 'The game opens in this window. It needs iOS/iPadOS 26 and about 8 GB of memory (an M-series iPad).'
                                : 'The game opens in this window. If it does not run, use Open in browser with Chrome or Edge.'
                          : Platform.isAndroid
                          ? 'The game opens in Chrome. It needs WebGPU and a graphics chip with BC texture support.'
                          : 'Use Chrome or Edge. The game needs WebGPU.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (Platform.isAndroid)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('enable-webgpu'),
                          onPressed: _enableWebGpuHelp,
                          icon: const Icon(Icons.memory),
                          label: const Text('Turn on WebGPU in Chrome'),
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
