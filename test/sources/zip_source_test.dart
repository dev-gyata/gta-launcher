import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';
import 'package:playgta5_launcher/sources/zip_source.dart';

void main() {
  late Directory cache;
  setUp(
    () async => cache = await Directory.systemTemp.createTemp('zip_source'),
  );
  tearDown(() async => cache.delete(recursive: true));

  test(
    'indexes roots and virtual directories without fetching large payloads',
    () async {
      final archive = _Archive([
        _Item('wrapper/b/8b0b5899ed/game.wasm', utf8.encode('wasm')),
        _Item('wrapper/data/first.bin', [1, 2, 3]),
        _Item('unrelated.bin', List.filled(150000, 7)),
      ]);
      final source = _MemorySource(archive.bytes);
      final zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
      addTearDown(zip.dispose);
      expect(zip.mirrorRoots, ['wrapper']);
      final root = zip.forRoot('wrapper');
      expect((await root.stat('b/8b0b5899ed/game.wasm'))!.size, 4);
      expect((await root.stat('data'))!.isDirectory, isTrue);
      expect(await root.stat('../unrelated.bin'), isNull);
      expect(await root.stat('missing'), isNull);
      expect(source.bytesRead, lessThan(70000));
    },
  );

  test(
    'stored entries translate only the requested range after validating header',
    () async {
      final archive = _Archive([
        _Item('data/file', utf8.encode('abcdef')),
        _Item('unrelated', List.filled(150000, 7)),
      ]);
      final source = _MemorySource(archive.bytes);
      final zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
      addTearDown(zip.dispose);
      source.ranges.clear();
      expect(
        await _read(zip.forRoot(''), 'data/file', 1, 4),
        utf8.encode('bcd'),
      );
      final offset = archive.offsets['data/file']!;
      expect(source.ranges.last, (offset + 1, offset + 4));
      expect(
        source.ranges.fold<int>(0, (n, r) => n + r.$2 - r.$1),
        lessThan(100),
      );
    },
  );

  test(
    'a stored local header can retry after a transient archive read failure',
    () async {
      final source = _MemorySource(
        _Archive([_Item('data/file', utf8.encode('abc'))]).bytes,
      );
      final zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
      addTearDown(zip.dispose);
      source.failOnceAt.add(0);
      final root = zip.forRoot('');
      await expectLater(
        _read(root, 'data/file', 0, 3),
        throwsA(isA<SourceException>()),
      );
      expect(await _read(root, 'data/file', 0, 3), utf8.encode('abc'));
    },
  );

  test(
    'failed shared preparation is retried and publishes a verified cache',
    () async {
      final archive = _Archive([
        _Item('data/file', utf8.encode('abcdef'), deflate: true),
      ]);
      final source = _MemorySource(archive.bytes);
      final zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
      addTearDown(zip.dispose);
      final payloadStart = archive.offsets['data/file']!;
      source.failOnceAt.add(payloadStart);
      final root = zip.forRoot('');
      final first = _read(root, 'data/file', 0, 3);
      final duplicate = _read(root, 'data/file', 3, 6);
      await Future.wait([
        expectLater(first, throwsA(isA<SourceException>())),
        expectLater(duplicate, throwsA(isA<SourceException>())),
      ]);
      expect(
        source.ranges.where((range) => range.$1 == payloadStart).length,
        1,
      );
      expect(await _read(root, 'data/file', 0, 6), utf8.encode('abcdef'));
      expect(
        source.ranges.where((range) => range.$1 == payloadStart).length,
        2,
      );
      final files = await cache
          .list(recursive: true)
          .where((file) => file is File)
          .toList();
      expect(files.where((file) => file.path.endsWith('.bin')).length, 1);
      expect(files.where((file) => file.path.endsWith('.complete')).length, 1);
    },
  );

  test('ZIP64 indexes sizes and offsets and serves a stored file', () async {
    final archive = _Archive([
      _Item('data/file', utf8.encode('zip64')),
    ], zip64: true);
    final zip = await ZipMirrorSource.open(
      _MemorySource(archive.bytes),
      'archive.zip',
      cache,
    );
    addTearDown(zip.dispose);
    expect(
      await _read(zip.forRoot(''), 'data/file', 1, 5),
      utf8.encode('ip64'),
    );
  });

  test('deflated ranges share preparation and persist independently', () async {
    final archive = _Archive([
      _Item('data/one', utf8.encode('abcdefghij'), deflate: true),
      _Item('data/two', utf8.encode('second file'), deflate: true),
      _Item('unrelated', List.filled(150000, 7)),
    ]);
    final source = _MemorySource(archive.bytes);
    var zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
    source.ranges.clear();
    final root = zip.forRoot('');
    expect(
      await Future.wait([
        _read(root, 'data/one', 0, 3),
        _read(root, 'data/one', 7, 10),
        _read(root, 'data/two', 0, 6),
      ]),
      [utf8.encode('abc'), utf8.encode('hij'), utf8.encode('second')],
    );
    final compressedStart = archive.offsets['data/one']!;
    expect(source.ranges.where((r) => r.$1 == compressedStart).length, 1);
    await zip.dispose();
    final next = _MemorySource(archive.bytes);
    zip = await ZipMirrorSource.open(next, 'archive.zip', cache);
    addTearDown(zip.dispose);
    next.ranges.clear();
    expect(await _read(zip.forRoot(''), 'data/one', 3, 7), utf8.encode('defg'));
    expect(next.ranges, isEmpty);
  });

  test('at most two distinct compressed entries prepare at once', () async {
    final archive = _Archive([
      _Item('data/a', utf8.encode('first'), deflate: true),
      _Item('data/b', utf8.encode('second'), deflate: true),
      _Item('data/c', utf8.encode('third'), deflate: true),
    ]);
    final source = _MemorySource(archive.bytes);
    final zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
    addTearDown(zip.dispose);
    final firstTwo = Completer<void>();
    final allThree = Completer<void>();
    for (final offset in archive.offsets.values) {
      source.gates[offset] = Completer<void>();
    }
    source.onBlocked = () {
      if (source.blockedStarts.length == 2) firstTwo.complete();
      if (source.blockedStarts.length == 3) allThree.complete();
    };
    final root = zip.forRoot('');
    final reads = Future.wait([
      _read(root, 'data/a', 0, 5),
      _read(root, 'data/b', 0, 6),
      _read(root, 'data/c', 0, 5),
    ]);
    await firstTwo.future;
    await Future<void>.delayed(Duration.zero);
    expect(source.blockedStarts.length, 2);
    source.gates[source.blockedStarts.first]!.complete();
    await allThree.future;
    for (final gate in source.gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    expect(await reads, [
      utf8.encode('first'),
      utf8.encode('second'),
      utf8.encode('third'),
    ]);
  });

  test('files without a matching completion marker are revalidated', () async {
    final archive = _Archive([
      _Item('data/file', utf8.encode('abc'), deflate: true),
    ]);
    final base = '0-${_crc32(utf8.encode('abc'))}-3';
    await File('${cache.path}/$base.bin').writeAsString('bad');
    await File(
      '${cache.path}/$base.complete',
    ).writeAsString('outdated archive');
    final zip = await ZipMirrorSource.open(
      _MemorySource(archive.bytes),
      'archive.zip',
      cache,
    );
    addTearDown(zip.dispose);
    expect(await _read(zip.forRoot(''), 'data/file', 0, 3), utf8.encode('abc'));
  });

  test(
    'a symbolic link cannot redirect the supplied cache directory',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'zip_cache_outside',
      );
      addTearDown(() => outside.delete(recursive: true));
      final redirected = '${cache.path}/redirected';
      await Link(redirected).create(outside.path);
      final zip = await ZipMirrorSource.open(
        _MemorySource(
          _Archive([
            _Item('data/file', utf8.encode('abc'), deflate: true),
          ]).bytes,
        ),
        'archive.zip',
        Directory(redirected),
      );
      addTearDown(zip.dispose);
      await expectLater(
        _read(zip.forRoot(''), 'data/file', 0, 3),
        throwsA(isA<SourceException>()),
      );
      expect(await outside.list().toList(), isEmpty);
    },
  );

  for (final extension in ['bin', 'complete']) {
    test(
      'rejects an existing symbolic link at a cache $extension destination',
      () async {
        final outside = await Directory.systemTemp.createTemp(
          'zip_cache_outside',
        );
        addTearDown(() => outside.delete(recursive: true));
        final external = File('${outside.path}/external');
        await external.writeAsString('unrelated');
        final base = '0-${_crc32(utf8.encode('abc'))}-3';
        await Link('${cache.path}/$base.$extension').create(external.path);
        final zip = await ZipMirrorSource.open(
          _MemorySource(
            _Archive([
              _Item('data/file', utf8.encode('abc'), deflate: true),
            ]).bytes,
          ),
          'archive.zip',
          cache,
        );
        addTearDown(zip.dispose);
        await expectLater(
          _read(zip.forRoot(''), 'data/file', 0, 3),
          throwsA(isA<SourceException>()),
        );
        expect(await external.readAsString(), 'unrelated');
      },
    );
  }

  test(
    'rejects symbolic links in existing temporary cache directories',
    () async {
      final temporary = await Directory('${cache.path}/preparing-old').create();
      await Link('${temporary.path}/member').create('${cache.path}/outside');
      final zip = await ZipMirrorSource.open(
        _MemorySource(
          _Archive([
            _Item('data/file', utf8.encode('abc'), deflate: true),
          ]).bytes,
        ),
        'archive.zip',
        cache,
      );
      addTearDown(zip.dispose);
      await expectLater(
        _read(zip.forRoot(''), 'data/file', 0, 3),
        throwsA(isA<SourceException>()),
      );
    },
  );

  test(
    'a verified cache file replaced by a link is rejected on its next read',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'zip_cache_outside',
      );
      addTearDown(() => outside.delete(recursive: true));
      final external = File('${outside.path}/external');
      await external.writeAsString('bad');
      final zip = await ZipMirrorSource.open(
        _MemorySource(
          _Archive([
            _Item('data/file', utf8.encode('abc'), deflate: true),
          ]).bytes,
        ),
        'archive.zip',
        cache,
      );
      addTearDown(zip.dispose);
      final root = zip.forRoot('');
      expect(await _read(root, 'data/file', 0, 3), utf8.encode('abc'));
      final cached = await cache
          .list()
          .where((entry) => entry.path.endsWith('.bin'))
          .single;
      await cached.delete();
      await Link(cached.path).create(external.path);
      await expectLater(
        _read(root, 'data/file', 0, 3),
        throwsA(isA<SourceException>()),
      );
      expect(await external.readAsString(), 'bad');
    },
  );

  test(
    'large deflated members verify streaming output before serving a range',
    () async {
      final payload = List<int>.generate(600000, (i) => i % 251);
      final zip = await ZipMirrorSource.open(
        _MemorySource(
          _Archive([_Item('data/large', payload, deflate: true)]).bytes,
        ),
        'archive.zip',
        cache,
      );
      addTearDown(zip.dispose);
      expect(await _read(zip.forRoot(''), 'data/large', 599990, 600000), [
        100,
        101,
        102,
        103,
        104,
        105,
        106,
        107,
        108,
        109,
      ]);
      final cached = await cache
          .list()
          .where((f) => f.path.endsWith('.bin'))
          .cast<File>()
          .single;
      expect(await cached.length(), 600000);
    },
  );

  test(
    'ZIP64 supports offsets beyond 4 GiB without downloading the gap',
    () async {
      const gap = 0x100000100;
      final archive = _Archive(
        [_Item('data/file', utf8.encode('large offset'))],
        zip64: true,
        baseOffset: gap,
      );
      final source = _SparseSource(archive.bytes, gap);
      final zip = await ZipMirrorSource.open(source, 'archive.zip', cache);
      addTearDown(zip.dispose);
      expect(
        await _read(zip.forRoot(''), 'data/file', 6, 12),
        utf8.encode('offset'),
      );
      expect(source.bytesRead, lessThan(70000));
    },
  );

  test(
    'root discovery requires both wasm and populated data descendants',
    () async {
      final zip = await ZipMirrorSource.open(
        _MemorySource(
          _Archive([
            _Item('b/8b0b5899ed/game.wasm', [1]),
            _Item('data/first', [2]),
            _Item('empty/b/8b0b5899ed/game.wasm', [3]),
            _Item('empty/data/', []),
            _Item('other/b/8b0b5899ed/game.wasm', [4]),
            _Item('other/data/sub/second', [5]),
          ]).bytes,
        ),
        'archive.zip',
        cache,
      );
      addTearDown(zip.dispose);
      expect(zip.mirrorRoots, ['', 'other']);
      expect(
        (await zip.forRoot('other/').stat('data/sub'))!.isDirectory,
        isTrue,
      );
      expect(await zip.forRoot('other').stat('/data'), isNull);
    },
  );

  test('absolute root prefixes cannot select the archive root', () async {
    final zip = await ZipMirrorSource.open(
      _MemorySource(
        _Archive([
          _Item('data/file', [1]),
        ]).bytes,
      ),
      'archive.zip',
      cache,
    );
    addTearDown(zip.dispose);
    expect(() => zip.forRoot('/'), throwsA(isA<SourceException>()));
  });

  test(
    'rejects central-directory size and count limits before fetching it',
    () async {
      final archive = _Archive([
        _Item('data/a', [1]),
      ], zip64: true);
      final record = ByteData.sublistView(
        archive.bytes,
        archive.bytes.length - 98,
      );
      record.setUint64(24, 100001, Endian.little);
      record.setUint64(32, 100001, Endian.little);
      final source = _MemorySource(archive.bytes);
      await expectLater(
        ZipMirrorSource.open(source, 'archive.zip', cache),
        throwsA(isA<SourceException>()),
      );
      expect(source.ranges.length, 3);
      record.setUint64(24, 1, Endian.little);
      record.setUint64(32, 1, Endian.little);
      record.setUint64(40, 64 * 1024 * 1024 + 1, Endian.little);
      await expectLater(
        ZipMirrorSource.open(source, 'archive.zip', cache),
        throwsA(isA<SourceException>()),
      );
    },
  );

  test('unsupported compression and split archives fail at indexing', () async {
    final archive = _Archive([
      _Item('data/a', [1]),
    ]);
    final directoryStart = archive.offsets['data/a']! + 1;
    final directory = ByteData.sublistView(archive.bytes, directoryStart);
    directory.setUint16(10, 12, Endian.little);
    await expectLater(
      ZipMirrorSource.open(_MemorySource(archive.bytes), 'archive.zip', cache),
      throwsA(isA<SourceException>()),
    );
    directory.setUint16(10, 0, Endian.little);
    directory.setUint16(34, 1, Endian.little);
    await expectLater(
      ZipMirrorSource.open(_MemorySource(archive.bytes), 'archive.zip', cache),
      throwsA(isA<SourceException>()),
    );
  });

  test('unvalidated cached files never bypass CRC checks', () async {
    final archive = _Archive([
      _Item('data/file', utf8.encode('abc'), deflate: true, crc: 0),
    ]);
    final zip = await ZipMirrorSource.open(
      _MemorySource(archive.bytes),
      'archive.zip',
      cache,
    );
    addTearDown(zip.dispose);
    await expectLater(
      _read(zip.forRoot(''), 'data/file', 0, 3),
      throwsA(isA<SourceException>()),
    );
    expect(
      await cache.list(recursive: true).where((e) => e is File).toList(),
      isEmpty,
    );
  });

  for (final item in [
    _Item('../evil', [1]),
    _Item('/evil', [1]),
    _Item('C:/evil', [1]),
    _Item('data\\evil', [1]),
    _Item('data/link', [1], mode: 0xa1ff),
    _Item('data/encrypted', [1], flags: 1),
  ]) {
    test('rejects unsafe or unsupported entry ${item.name}', () async {
      await expectLater(
        ZipMirrorSource.open(
          _MemorySource(_Archive([item]).bytes),
          'archive.zip',
          cache,
        ),
        throwsA(isA<SourceException>()),
      );
    });
  }

  test('rejects duplicate names and malformed local headers', () async {
    await expectLater(
      ZipMirrorSource.open(
        _MemorySource(
          _Archive([
            _Item('a', [1]),
            _Item('a', [2]),
          ]).bytes,
        ),
        'archive.zip',
        cache,
      ),
      throwsA(isA<SourceException>()),
    );
    final archive = _Archive([
      _Item('data/file', [1, 2, 3]),
    ]);
    archive.bytes[0] = 0;
    final zip = await ZipMirrorSource.open(
      _MemorySource(archive.bytes),
      'archive.zip',
      cache,
    );
    addTearDown(zip.dispose);
    await expectLater(
      _read(zip.forRoot(''), 'data/file', 0, 2),
      throwsA(isA<SourceException>()),
    );
  });

  test(
    'cancellation interrupts blocked preparation and removes partial files',
    () async {
      final archive = _Archive([
        _Item('data/file', List.filled(200000, 7), deflate: true),
      ]);
      final source = _MemorySource(archive.bytes);
      final cancellation = SourceCancellation();
      final zip = await ZipMirrorSource.open(
        source,
        'archive.zip',
        cache,
        cancellation: cancellation,
      );
      source.blockFrom = archive.offsets['data/file'];
      final read = _read(zip.forRoot(''), 'data/file', 0, 2);
      final failure = expectLater(read, throwsA(isA<SourceCancelled>()));
      await source.blocked.future;
      cancellation.cancel();
      await failure;
      await zip.dispose();
      expect(
        await cache.list(recursive: true).where((e) => e is File).toList(),
        isEmpty,
      );
    },
  );
}

Future<List<int>> _read(MirrorSource source, String path, int start, int end) =>
    source.read(path, start, end).expand((bytes) => bytes).toList();

class _MemorySource implements MirrorSource {
  _MemorySource(this.bytes);
  final List<int> bytes;
  final List<(int, int)> ranges = [];
  int get bytesRead => ranges.fold(0, (n, r) => n + r.$2 - r.$1);
  int? blockFrom;
  final blocked = Completer<void>();
  final Map<int, Completer<void>> gates = {};
  final Set<int> blockedStarts = {};
  final Set<int> failOnceAt = {};
  void Function()? onBlocked;
  @override
  String get identity => 'test-archive';
  @override
  Future<SourceFile?> stat(String path) async => SourceFile(bytes.length);
  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    ranges.add((start, end));
    if (failOnceAt.remove(start)) {
      throw const SourceException('Transient archive read failure');
    }
    if (start == blockFrom) {
      blocked.complete();
      await Completer<void>().future;
    }
    final gate = gates[start];
    if (gate != null) {
      blockedStarts.add(start);
      onBlocked?.call();
      await gate.future;
    }
    for (var i = start; i < end; i += 1024) {
      yield bytes.sublist(i, i + 1024 < end ? i + 1024 : end);
    }
  }

  @override
  Future<void> dispose() async {}
}

class _SparseSource implements MirrorSource {
  _SparseSource(this.bytes, this.offset);
  final Uint8List bytes;
  final int offset;
  int bytesRead = 0;
  @override
  String get identity => 'sparse-archive';
  @override
  Future<SourceFile?> stat(String path) async =>
      SourceFile(offset + bytes.length);
  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    bytesRead += end - start;
    final result = Uint8List(end - start);
    final overlap = start < offset ? offset : start;
    if (overlap < end) {
      result.setRange(overlap - start, end - start, bytes, overlap - offset);
    }
    yield result;
  }

  @override
  Future<void> dispose() async {}
}

class _Item {
  _Item(
    this.name,
    this.bytes, {
    this.deflate = false,
    this.flags = 0,
    this.mode = 0x81a4,
    this.crc,
  });
  final String name;
  final List<int> bytes;
  final bool deflate;
  final int flags;
  final int mode;
  final int? crc;
}

class _Archive {
  _Archive(List<_Item> items, {bool zip64 = false, int baseOffset = 0}) {
    final data = BytesBuilder();
    final central = BytesBuilder();
    for (final item in items) {
      final name = utf8.encode(item.name);
      final compressed = item.deflate
          ? ZLibEncoder(raw: true).convert(item.bytes)
          : item.bytes;
      final crc = item.crc ?? _crc32(item.bytes);
      final offset = baseOffset + data.length;
      final local = ByteData(30);
      local.setUint32(0, 0x04034b50, Endian.little);
      local.setUint16(4, 20, Endian.little);
      local.setUint16(6, item.flags, Endian.little);
      local.setUint16(8, item.deflate ? 8 : 0, Endian.little);
      local.setUint32(14, crc, Endian.little);
      local.setUint32(18, compressed.length, Endian.little);
      local.setUint32(22, item.bytes.length, Endian.little);
      local.setUint16(26, name.length, Endian.little);
      data.add(local.buffer.asUint8List());
      data.add(name);
      offsets[item.name] = baseOffset + data.length;
      data.add(compressed);
      final directory = ByteData(46);
      directory.setUint32(0, 0x02014b50, Endian.little);
      directory.setUint16(4, 0x031e, Endian.little);
      directory.setUint16(6, zip64 ? 45 : 20, Endian.little);
      directory.setUint16(8, item.flags, Endian.little);
      directory.setUint16(10, item.deflate ? 8 : 0, Endian.little);
      directory.setUint32(16, crc, Endian.little);
      directory.setUint32(
        20,
        zip64 ? 0xffffffff : compressed.length,
        Endian.little,
      );
      directory.setUint32(
        24,
        zip64 ? 0xffffffff : item.bytes.length,
        Endian.little,
      );
      directory.setUint16(28, name.length, Endian.little);
      directory.setUint16(30, zip64 ? 28 : 0, Endian.little);
      directory.setUint32(38, item.mode << 16, Endian.little);
      directory.setUint32(42, zip64 ? 0xffffffff : offset, Endian.little);
      central.add(directory.buffer.asUint8List());
      central.add(name);
      if (zip64) {
        final extra = ByteData(28);
        extra.setUint16(0, 1, Endian.little);
        extra.setUint16(2, 24, Endian.little);
        extra.setUint64(4, item.bytes.length, Endian.little);
        extra.setUint64(12, compressed.length, Endian.little);
        extra.setUint64(20, offset, Endian.little);
        central.add(extra.buffer.asUint8List());
      }
    }
    final centralStart = baseOffset + data.length;
    final centralSize = central.length;
    data.add(central.takeBytes());
    if (zip64) {
      final zip64Start = baseOffset + data.length;
      final record = ByteData(56);
      record.setUint32(0, 0x06064b50, Endian.little);
      record.setUint64(4, 44, Endian.little);
      record.setUint64(24, items.length, Endian.little);
      record.setUint64(32, items.length, Endian.little);
      record.setUint64(40, centralSize, Endian.little);
      record.setUint64(48, centralStart, Endian.little);
      data.add(record.buffer.asUint8List());
      final locator = ByteData(20);
      locator.setUint32(0, 0x07064b50, Endian.little);
      locator.setUint64(8, zip64Start, Endian.little);
      locator.setUint32(16, 1, Endian.little);
      data.add(locator.buffer.asUint8List());
    }
    final end = ByteData(22);
    end.setUint32(0, 0x06054b50, Endian.little);
    end.setUint16(8, zip64 ? 0xffff : items.length, Endian.little);
    end.setUint16(10, zip64 ? 0xffff : items.length, Endian.little);
    end.setUint32(12, zip64 ? 0xffffffff : centralSize, Endian.little);
    end.setUint32(16, zip64 ? 0xffffffff : centralStart, Endian.little);
    data.add(end.buffer.asUint8List());
    bytes = data.takeBytes();
  }
  late final Uint8List bytes;
  final Map<String, int> offsets = {};
}

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  return crc ^ 0xffffffff;
}
