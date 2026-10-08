import '../server/site_files.dart';
import 'mirror_source.dart';

List<String> discoverMirrorRoots(Iterable<String> paths) {
  final files = paths.where(safeSourcePath).toSet();
  final wasm = '${buildPath.substring(1)}/game.wasm';
  final roots = <String>[];
  final populatedDataRoots = <String>{};
  for (final file in files) {
    final parts = file.split('/');
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i] == 'data') {
        populatedDataRoots.add(i == 0 ? '' : '${parts.take(i).join('/')}/');
      }
    }
  }
  for (final path in files) {
    if (path != wasm && !path.endsWith('/$wasm')) continue;
    final prefix = path.substring(0, path.length - wasm.length);
    if (populatedDataRoots.contains(prefix)) roots.add(prefix);
  }
  return roots..sort();
}

class PrefixMirrorSource implements MirrorSource {
  PrefixMirrorSource(this.source, this.prefix) {
    if (!safeSourcePath(prefix) ||
        (prefix.isNotEmpty && !prefix.endsWith('/'))) {
      throw const FormatException('Invalid mirror root prefix');
    }
  }
  final MirrorSource source;
  final String prefix;
  @override
  String get identity => '${source.identity}:$prefix';
  @override
  Future<SourceFile?> stat(String path) =>
      safeSourcePath(path) ? source.stat('$prefix$path') : Future.value();
  @override
  Stream<List<int>> read(String path, int start, int end) {
    if (!safeSourcePath(path)) {
      return Stream.error(
        const SourceException('Invalid source path', status: 404),
      );
    }
    return source.read('$prefix$path', start, end);
  }

  @override
  Future<void> dispose() => source.dispose();
}

/// A ZIP index borrows the shared torrent source; its owner closes the engine.
class BorrowedMirrorSource implements MirrorSource {
  BorrowedMirrorSource(this.source);
  final MirrorSource source;
  @override
  String get identity => source.identity;
  @override
  Future<SourceFile?> stat(String path) => source.stat(path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      source.read(path, start, end);
  @override
  Future<void> dispose() async {}
}
