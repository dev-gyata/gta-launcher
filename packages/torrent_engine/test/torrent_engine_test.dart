// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:torrent_engine/torrent_engine.dart';

List<int> pattern(int size, int seed) =>
    List.generate(size, (i) => (i * 31 + seed) % 251);
Future<List<int>> collect(Stream<List<int>> stream) async => [
  await for (final bytes in stream) ...bytes,
];

void main() {
  test('invalid magnets fail with readable exceptions', () async {
    final cache = await Directory.systemTemp.createTemp('torrent-invalid-');
    try {
      await expectLater(
        TorrentEngine.open('invalid magnet', cache.path),
        throwsA(
          isA<TorrentEngineException>().having(
            (e) => e.message,
            'message',
            contains('Invalid magnet'),
          ),
        ),
      );
    } finally {
      await cache.delete(recursive: true);
    }
  });

  test('disk usage measures allocation and ignores symlinks', () async {
    final cache = await Directory.systemTemp.createTemp('torrent-usage-');
    final outside = await Directory.systemTemp.createTemp('torrent-outside-');
    try {
      const size = 128 * 1024 * 1024;
      final sparseFile = File('${cache.path}/sparse');
      final sparse = await sparseFile.open(mode: FileMode.write);
      await sparse.writeFrom(List.filled(4096, 5));
      await sparse.truncate(size);
      await sparse.close();
      expect(await sparseFile.length(), size);
      if (Platform.isWindows) {
        // Mark the finished fixture, then deallocate its zero-filled range.
        // Opening with O_TRUNC can clear the sparse attribute on Windows.
        for (final arguments in [
          ['sparse', 'setflag', sparseFile.path],
          ['sparse', 'setrange', sparseFile.path, '4096', '${size - 4096}'],
        ]) {
          final result = await Process.run('fsutil', arguments);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
        }
      }
      final bytes = await TorrentEngine.cacheDiskUsage(cache.path);
      expect(bytes, greaterThan(0));
      expect(bytes, lessThan(128 * 1024 * 1024));
      if (!Platform.isWindows) {
        await File(
          '${outside.path}/payload',
        ).writeAsBytes(List.filled(65536, 9));
        await Link('${cache.path}/external').create(outside.path);
        expect(await TorrentEngine.cacheDiskUsage(cache.path), bytes);
      }
    } finally {
      await cache.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });

  final fixture = Platform.environment['TORRENT_ENGINE_FIXTURE'];
  test(
    'worker streams cross-piece concurrent ranges and resumes offline',
    () async {
      final root = await Directory.systemTemp.createTemp('torrent-peer-');
      final peer = await Process.start(fixture!, [root.path, '--serve']);
      final errors = StringBuffer();
      final errorSubscription = peer.stderr
          .transform(utf8.decoder)
          .listen(errors.write);
      final magnet = await peer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20));
      TorrentEngine? engine;
      try {
        engine = await TorrentEngine.open(magnet, '${root.path}/cache');
        final files = await engine.files().timeout(const Duration(seconds: 20));
        expect(files.map((file) => file.path), [
          'fixture/a.bin',
          'fixture/b.bin',
        ]);
        expect(await engine.cachedBytes(), 0);
        final expected = pattern(110000, 7);
        final results = await Future.wait([
          collect(engine.read(1, 0, 20000)),
          collect(engine.read(1, 10000, 70000)),
        ]).timeout(const Duration(seconds: 20));
        expect(results[0], expected.sublist(0, 20000));
        expect(results[1], expected.sublist(10000, 70000));
        expect(await engine.cachedBytes(), lessThan(150000));
        await engine.dispose();
        engine = null;
        peer.stdin.writeln('stop');
        await peer.stdin.close();
        expect(await peer.exitCode, 0, reason: errors.toString());
        engine = await TorrentEngine.open(magnet, '${root.path}/cache');
        expect(
          await engine.files().timeout(const Duration(seconds: 3)),
          hasLength(2),
        );
        expect(
          await collect(
            engine.read(1, 10000, 70000),
          ).timeout(const Duration(seconds: 3)),
          expected.sublist(10000, 70000),
        );
        final stalled = engine
            .read(1, 100000, 110000)
            .listen((_) {}, onError: (_) {});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await stalled.cancel().timeout(const Duration(seconds: 1));
        expect(await engine.cachedBytes(), greaterThan(0));
        await expectLater(collect(engine.read(1, -1, 1)), throwsRangeError);
        await engine.dispose();
        await engine.dispose();
        engine = null;
      } finally {
        await engine?.dispose();
        peer.kill();
        await errorSubscription.cancel();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    skip: fixture == null
        ? 'Set TORRENT_ENGINE_FIXTURE to the CMake integration executable.'
        : false,
  );

  test('dispose cancels metadata discovery promptly', () async {
    final cache = await Directory.systemTemp.createTemp('torrent-dispose-');
    final engine = await TorrentEngine.open(
      'magnet:?xt=urn:btih:0000000000000000000000000000000000000001',
      cache.path,
    );
    final files = engine.files();
    final failed = expectLater(files, throwsA(isA<TorrentEngineException>()));
    await engine.dispose().timeout(const Duration(seconds: 8));
    await failed;
    await cache.delete(recursive: true);
  });
}
