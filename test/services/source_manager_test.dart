import 'dart:io';
import 'dart:async';
import 'package:torrent_engine/torrent_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/services/source_manager.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';
import 'package:playgta5_launcher/sources/source_selection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('opens a local mirror from its parent folder', () async {
    final dir = await Directory.systemTemp.createTemp('manager');
    addTearDown(() => dir.delete(recursive: true));
    final root = '${dir.path}/mirror/playgta5.com';
    await Directory('$root/b/8b0b5899ed').create(recursive: true);
    await Directory('$root/data').create();
    await File('$root/b/8b0b5899ed/game.wasm').writeAsString('wasm');
    final source = await const SourceManager().open(
      SourceKind.local,
      dir.path,
      cancellation: SourceCancellation(),
    );
    addTearDown(source.dispose);
    expect((await source.stat('b/8b0b5899ed/game.wasm'))!.size, 4);
  });
  test('cancelled startup does not open sources or create caches', () async {
    final dir = await Directory.systemTemp.createTemp('manager');
    addTearDown(() => dir.delete(recursive: true));
    final cache = Directory('${dir.path}/cache');
    final cancellation = SourceCancellation()..cancel();
    final manager = SourceManager(cacheDirectory: cache);
    await expectLater(
      manager.open(
        SourceKind.magnet,
        'magnet:?xt=urn:btih:57a4193cc3d3f069ce436fcda040ed4c705b76c7',
        cancellation: cancellation,
      ),
      throwsA(isA<SourceCancelled>()),
    );
    expect(await cache.exists(), isFalse);
  });
  test(
    'clear cache rejects a symlink instead of deleting its target',
    () async {
      final dir = await Directory.systemTemp.createTemp('manager');
      addTearDown(() => dir.delete(recursive: true));
      final outside = Directory('${dir.path}/outside');
      await outside.create();
      await File('${outside.path}/keep').writeAsString('keep');
      final link = '${dir.path}/cache';
      await Link(link).create(outside.path);
      await expectLater(
        SourceManager(cacheDirectory: Directory(link)).clearCache(),
        throwsA(isA<SourceException>()),
      );
      expect(await File('${outside.path}/keep').readAsString(), 'keep');
    },
  );
  test('clears retained cache while preserving unrelated files', () async {
    final dir = await Directory.systemTemp.createTemp('manager');
    addTearDown(() => dir.delete(recursive: true));
    final cache = Directory('${dir.path}/cache');
    await cache.create();
    await File('${cache.path}/resume.dat').writeAsString('resume');
    await File('${dir.path}/keep').writeAsString('keep');
    await SourceManager(cacheDirectory: cache).clearCache();
    expect(await cache.exists(), isFalse);
    expect(await File('${dir.path}/keep').readAsString(), 'keep');
  });
  test(
    'Stop waits for a pending native opener before releasing cache ownership',
    () async {
      final dir = await Directory.systemTemp.createTemp('manager');
      addTearDown(() => dir.delete(recursive: true));
      final started = Completer<void>();
      final opening = Completer<TorrentEngine>();
      final cancellation = SourceCancellation();
      final manager = SourceManager(
        cacheDirectory: Directory('${dir.path}/cache'),
        torrentOpener: (magnet, path, {onLog}) {
          started.complete();
          return opening.future;
        },
      );
      var settled = false;
      final result = manager
          .open(
            SourceKind.magnet,
            'magnet:?xt=urn:btih:57a4193cc3d3f069ce436fcda040ed4c705b76c7',
            cancellation: cancellation,
          )
          .whenComplete(() => settled = true);
      final failed = expectLater(result, throwsA(isA<SourceCancelled>()));
      await started.future;
      cancellation.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        settled,
        isFalse,
        reason:
            'Clear cache and a new Start must wait for native startup cleanup',
      );
      opening.completeError(StateError('opener stopped'));
      await failed;
      expect(settled, isTrue);
    },
  );
}
