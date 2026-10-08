import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../server/site_files.dart';

class SourceFile {
  const SourceFile(this.size, {this.isDirectory = false, this.modified});
  final int size;
  final bool isDirectory;
  final DateTime? modified;
}

class SourceException implements Exception {
  const SourceException(this.message, {this.status = 502});
  final String message;
  final int status;
  @override
  String toString() => message;
}

class SourceCancelled extends SourceException {
  const SourceCancelled() : super('Source stopped', status: 503);
}

/// Shared by startup, requests, and extraction; cancellation is terminal.
class SourceCancellation {
  final _done = Completer<void>();
  bool get cancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!cancelled) _done.complete();
  }

  void check() {
    if (cancelled) throw const SourceCancelled();
  }

  Future<T> bind<T>(Future<T> work) {
    check();
    return Future.any([
      work,
      whenCancelled.then<T>((_) => throw const SourceCancelled()),
    ]);
  }
}

/// Paths are decoded, relative POSIX paths. Range ends are exclusive.
abstract class MirrorSource {
  String get identity;
  Future<SourceFile?> stat(String path);
  Stream<List<int>> read(String path, int start, int end);
  Future<void> dispose();
}

bool safeSourcePath(String path) =>
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.contains('\u0000') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
    !path.split('/').any((s) => s == '..' || s == '.');

class LocalMirrorSource implements MirrorSource {
  LocalMirrorSource(String root) : root = p.normalize(p.absolute(root));
  final String root;
  final cancellation = SourceCancellation();
  @override
  String get identity => 'local:$root';
  Future<String?> _resolve(String path) async {
    cancellation.check();
    if (!safeSourcePath(path)) return null;
    final candidate = p.joinAll([root, ...path.split('/')]);
    try {
      final realRoot = await Directory(root).resolveSymbolicLinks();
      final real = await File(candidate).resolveSymbolicLinks();
      return real == realRoot || p.isWithin(realRoot, real) ? real : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<SourceFile?> stat(String path) async {
    final file = await _resolve(path);
    if (file == null) return null;
    final info = await FileStat.stat(file);
    if (info.type == FileSystemEntityType.notFound) return null;
    return SourceFile(
      info.size,
      isDirectory: info.type == FileSystemEntityType.directory,
      modified: info.modified,
    );
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    final file = await _resolve(path);
    if (file == null) {
      throw const SourceException('File not found', status: 404);
    }
    await for (final bytes in File(file).openRead(start, end)) {
      cancellation.check();
      yield bytes;
    }
  }

  @override
  Future<void> dispose() async => cancellation.cancel();
}

/// A small read also prepares a compressed ZIP engine before opening the game.
Future<void> validateMirrorEngine(MirrorSource source) async {
  final path = '${buildPath.substring(1)}/game.wasm';
  final info = await source.stat(path);
  if (info == null || info.isDirectory || info.size < 4) {
    throw const SourceException('Mirror engine is missing or truncated');
  }
  final bytes = await source.read(path, 0, 4).expand((chunk) => chunk).toList();
  if (bytes.length != 4 ||
      bytes[0] != 0 ||
      bytes[1] != 97 ||
      bytes[2] != 115 ||
      bytes[3] != 109) {
    throw const SourceException('Mirror engine is not a WebAssembly file');
  }
}
