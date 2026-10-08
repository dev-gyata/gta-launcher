import 'package:torrent_engine/torrent_engine.dart';
import 'mirror_source.dart';

/// Exposes the complete torrent file table; prefix/ZIP views select a mirror.
class TorrentMirrorSource implements MirrorSource {
  TorrentMirrorSource(
    this.engine,
    List<TorrentFile> files,
    this.identity,
    this.cancellation,
  ) {
    if (files.length > 100000) {
      throw const SourceException('Torrent contains too many files');
    }
    for (final file in files) {
      if (!safeSourcePath(file.path) || file.path.isEmpty || file.size < 0) {
        throw const SourceException('Torrent contains an unsafe file path');
      }
      if (_files.containsKey(file.path)) {
        throw const SourceException('Torrent contains duplicate paths');
      }
      _files[file.path] = file;
    }
  }
  final TorrentEngine engine;
  final SourceCancellation cancellation;
  final _files = <String, TorrentFile>{};
  Iterable<String> get paths => _files.keys;
  @override
  final String identity;
  @override
  Future<SourceFile?> stat(String path) async {
    cancellation.check();
    if (!safeSourcePath(path)) return null;
    final file = _files[path];
    if (file != null) return SourceFile(file.size);
    final prefix = path.isEmpty ? '' : '$path/';
    if (_files.keys.any((name) => name.startsWith(prefix))) {
      return const SourceFile(0, isDirectory: true);
    }
    return null;
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    cancellation.check();
    final file = _files[path];
    if (file == null || !safeSourcePath(path)) {
      throw const SourceException('Torrent file not found', status: 404);
    }
    try {
      await for (final bytes in engine.read(file.index, start, end)) {
        cancellation.check();
        yield bytes;
      }
    } on TorrentEngineException catch (e) {
      cancellation.check();
      final message = e.message.toLowerCase();
      throw SourceException(
        e.message,
        status:
            message.contains('timed out') ||
                message.contains('timeout') ||
                message.contains('stalled')
            ? 504
            : 502,
      );
    }
  }

  @override
  Future<void> dispose() async {
    cancellation.cancel();
    await engine.dispose();
  }
}
