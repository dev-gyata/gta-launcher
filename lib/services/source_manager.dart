import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:torrent_engine/torrent_engine.dart';
import '../sources/http_source.dart';
import '../sources/magnet.dart';
import '../sources/mirror_source.dart';
import '../sources/prefix_source.dart';
import '../sources/source_selection.dart';
import '../sources/torrent_source.dart';
import '../sources/zip_source.dart';
import 'mirror_validator.dart';

typedef TorrentOpener =
    Future<TorrentEngine> Function(
      String magnet,
      String cachePath, {
      void Function(String)? onLog,
    });

class SourceManager {
  const SourceManager({
    this.cacheDirectory,
    this.torrentOpener = TorrentEngine.open,
  });
  final TorrentOpener torrentOpener;
  final Directory? cacheDirectory;
  Future<Directory> _cache() async {
    final dir =
        cacheDirectory ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'torrent-cache',
          ),
        );
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const SourceException('Torrent cache cannot be a symbolic link');
    }
    return dir;
  }

  Future<int> cacheBytes() async {
    final cache = await _cache();
    return await cache.exists() ? TorrentEngine.cacheDiskUsage(cache.path) : 0;
  }

  Future<void> clearCache() async {
    final cache = await _cache();
    if (await cache.exists()) await cache.delete(recursive: true);
  }

  Future<Directory> _subdirectory(Directory root, List<String> parts) async {
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const SourceException('Torrent cache cannot be a symbolic link');
    }
    await root.create(recursive: true);
    final canonical = await root.resolveSymbolicLinks();
    var current = Directory(canonical);
    for (final part in parts) {
      current = Directory(p.join(current.path, part));
      final type = await FileSystemEntity.type(
        current.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw const SourceException(
          'Torrent cache contains an unsafe directory',
        );
      }
      await current.create();
      final real = await current.resolveSymbolicLinks();
      if (!p.isWithin(canonical, real)) {
        throw const SourceException('Torrent cache escapes its root');
      }
    }
    return current;
  }

  Future<MirrorSource> open(
    SourceKind kind,
    String value, {
    required SourceCancellation cancellation,
    void Function(String)? onLog,
    Future<String?> Function(List<String>)? chooseRoot,
  }) async {
    cancellation.check();
    value = value.trim();
    if (kind == SourceKind.local) {
      final root = resolveMirrorRoot(value);
      if (root == null) {
        throw const SourceException(
          'No game.wasm + data/ found in this folder',
        );
      }
      return LocalMirrorSource(root);
    }
    if (kind == SourceKind.http) {
      final manifest =
          jsonDecode(await rootBundle.loadString('site/data-manifest.json'))
              as Map<String, dynamic>;
      cancellation.check();
      final probe = (manifest['files'] as List).first[0] as String;
      return HttpMirrorSource.discover(
        Uri.parse(value),
        dataProbe: probe,
        cancellation: cancellation,
        onLog: onLog,
      );
    }
    final magnet = parseMagnet(value);
    final cache = await _cache();
    final dir = await _subdirectory(cache, [magnet.hash]);
    cancellation.check();
    TorrentEngine? engine;
    Future<TorrentEngine>? opening;
    TorrentMirrorSource? torrent;
    final zips = <ZipMirrorSource>[];
    try {
      onLog?.call('Discovering torrent metadata…');
      opening = torrentOpener(magnet.uri.toString(), dir.path, onLog: onLog)
          .then((opened) async {
            engine = opened;
            if (cancellation.cancelled) {
              await opened.dispose();
              throw const SourceCancelled();
            }
            return opened;
          });
      await cancellation.bind(opening);
      // Dispose even if cancellation happens before metadata or mirror selection.
      cancellation.whenCancelled
          .then((_) async {
            await engine?.dispose();
          })
          .catchError((Object e) {
            onLog?.call('Torrent shutdown: $e');
          });
      final files = await cancellation.bind(engine!.files());
      torrent = TorrentMirrorSource(
        engine!,
        files,
        'torrent:${magnet.hash}',
        cancellation,
      );
      final choices = <String, MirrorSource>{};
      for (final root in discoverMirrorRoots(torrent.paths)) {
        choices[root.isEmpty ? '(torrent root)' : root] = PrefixMirrorSource(
          BorrowedMirrorSource(torrent),
          root,
        );
      }
      final archives = torrent.paths
          .where((path) => path.toLowerCase().endsWith('.zip'))
          .toList();
      if (archives.length > 64) {
        throw const SourceException(
          'Torrent contains too many ZIP archives to index',
        );
      }
      for (final archive in archives) {
        cancellation.check();
        try {
          final archiveId = sha256.convert(utf8.encode(archive)).toString();
          final extractionCache = await _subdirectory(dir, [
            'extracted',
            archiveId,
          ]);
          final zip = await ZipMirrorSource.open(
            BorrowedMirrorSource(torrent),
            archive,
            extractionCache,
            cancellation: cancellation,
            onLog: onLog,
          );
          zips.add(zip);
          for (final root in zip.mirrorRoots) {
            choices['$archive :: ${root.isEmpty ? '(archive root)' : root}'] =
                zip.forRoot(root);
          }
        } on SourceCancelled {
          rethrow;
        } on SourceException catch (e) {
          onLog?.call('Cannot use $archive: $e');
        }
      }
      if (choices.isEmpty) {
        throw const SourceException(
          'Torrent contains no compatible unpacked mirror or supported ZIP mirror',
        );
      }
      var selected = choices.keys.first;
      if (choices.length > 1) {
        if (chooseRoot == null) {
          throw const SourceException(
            'Multiple mirror roots found; choose one in the launcher',
          );
        }
        final picked = await cancellation.bind(
          chooseRoot(choices.keys.toList()),
        );
        if (picked == null) throw const SourceCancelled();
        if (!choices.containsKey(picked)) {
          throw const SourceException('Invalid mirror root selection');
        }
        selected = picked;
      }
      cancellation.check();
      onLog?.call('Using $selected; checking the mirror engine…');
      await cancellation.bind(validateMirrorEngine(choices[selected]!));
      final owner = torrent;
      return _OwnedSource(choices[selected]!, () async {
        cancellation.cancel();
        await Future.wait(zips.map((zip) => zip.dispose()));
        await owner.dispose();
      });
    } catch (e) {
      cancellation.cancel();
      // Stop owns native startup until its completion and any late disposal settle.
      if (opening != null) {
        try {
          await opening;
        } catch (_) {
          /* Preserve the original startup error. */
        }
      }
      await Future.wait(zips.map((zip) => zip.dispose()));
      await engine?.dispose();
      if (e is TorrentEngineException) {
        throw SourceException(
          e.message,
          status: e.message.toLowerCase().contains('timed out') ? 504 : 502,
        );
      }
      rethrow;
    }
  }
}

class _OwnedSource implements MirrorSource {
  _OwnedSource(this.source, this.close);
  final MirrorSource source;
  final Future<void> Function() close;
  Future<void>? _disposing;
  @override
  String get identity => source.identity;
  @override
  Future<SourceFile?> stat(String path) => source.stat(path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      source.read(path, start, end);
  @override
  Future<void> dispose() => _disposing ??= close();
}
