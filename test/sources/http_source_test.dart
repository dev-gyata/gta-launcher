import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/sources/http_source.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';

void main() {
  late HttpServer upstream;
  late HttpMirrorSource source;
  var ignoreRange = false;
  var wrongRange = false;
  var truncated = false;
  var stalled = false;
  var invalidEngine = false;
  final requested = <String>[];
  setUp(() async {
    ignoreRange = false;
    wrongRange = false;
    truncated = false;
    stalled = false;
    invalidEngine = false;
    requested.clear();
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      requested.add(request.uri.path);
      final res = request.response;
      if (request.uri.path == '/redirect/file') {
        res.statusCode = 302;
        res.headers.set('location', '/base/playgta5.com/file');
        await res.close();
        return;
      }
      if (request.uri.path.endsWith('/missing')) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      if (request.uri.path.endsWith('/loop')) {
        res.statusCode = 302;
        res.headers.set('location', request.uri.path);
        await res.close();
        return;
      }
      if (!request.uri.path.startsWith('/base/playgta5.com/')) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final bytes = request.uri.path.endsWith('/game.wasm') && !invalidEngine
          ? [0, 97, 115, 109, 1, 0]
          : 'abcdef'.codeUnits;
      final range = RegExp(
        r'bytes=(\d+)-(\d+)',
      ).firstMatch(request.headers.value('range') ?? '');
      if (range != null && !ignoreRange) {
        final a = int.parse(range[1]!);
        final b = int.parse(range[2]!).clamp(0, 5);
        res.statusCode = 206;
        res.headers.set(
          'content-range',
          'bytes ${wrongRange ? a + 1 : a}-$b/6',
        );
        if (stalled) {
          await res.flush();
          return;
        }
        if (!truncated) res.contentLength = b - a + 1;
        res.add(bytes.sublist(a, truncated ? b : b + 1));
      } else {
        res.contentLength = bytes.length;
        if (request.method != 'HEAD') res.add(bytes);
      }
      await res.close();
    });
    source = HttpMirrorSource(
      Uri.parse('http://127.0.0.1:${upstream.port}/base/playgta5.com/'),
    );
  });
  tearDown(() async {
    await source.dispose();
    await upstream.close(force: true);
  });
  test('discovers child mirror preserving base path', () async {
    final found = await HttpMirrorSource.discover(
      Uri.parse('http://127.0.0.1:${upstream.port}/base/'),
      dataProbe: 'common/file',
    );
    addTearDown(found.dispose);
    expect(found.identity, endsWith('/base/playgta5.com/'));
    expect(requested, contains('/base/playgta5.com/data/common/file'));
  });
  test('streams exactly requested bytes', () async {
    expect((await source.stat('file'))!.size, 6);
    expect(await source.read('file', 1, 4).expand((b) => b).toList(), [
      98,
      99,
      100,
    ]);
  });
  test('rejects ignored and mismatched range responses', () async {
    ignoreRange = true;
    await expectLater(
      source.read('file', 1, 4).drain<void>(),
      throwsA(isA<SourceException>()),
    );
    ignoreRange = false;
    wrongRange = true;
    await expectLater(
      source.read('file', 1, 4).drain<void>(),
      throwsA(isA<SourceException>()),
    );
  });
  test('rejects traversal and cancels terminally', () async {
    expect(await source.stat('../secret'), isNull);
    await source.dispose();
    await expectLater(source.stat('file'), throwsA(isA<SourceCancelled>()));
  });
  test('follows relative redirects', () async {
    final redirect = HttpMirrorSource(
      Uri.parse('http://127.0.0.1:${upstream.port}/redirect/'),
    );
    addTearDown(redirect.dispose);
    expect(await redirect.read('file', 0, 2).expand((b) => b).toList(), [
      97,
      98,
    ]);
  });
  test('missing files return null and excessive redirects fail', () async {
    expect(await source.stat('missing'), isNull);
    await expectLater(
      source.read('loop', 0, 1).drain<void>(),
      throwsA(isA<SourceException>()),
    );
  });
  test('encoded filenames remain within the base URL', () async {
    expect(await source.read('a b%file', 0, 1).expand((b) => b).toList(), [97]);
    expect(requested.last, '/base/playgta5.com/a%20b%25file');
  });
  test('rejects truncated bodies', () async {
    truncated = true;
    await expectLater(
      source.read('file', 0, 4).drain<void>(),
      throwsA(isA<SourceException>()),
    );
  });
  test('stalled body becomes a gateway timeout', () async {
    stalled = true;
    final short = HttpMirrorSource(
      source.base,
      timeout: const Duration(milliseconds: 50),
    );
    addTearDown(short.dispose);
    await expectLater(
      short.read('file', 0, 4).drain<void>(),
      throwsA(isA<SourceException>().having((e) => e.status, 'status', 504)),
    );
  });
  test('disposing interrupts a stalled body immediately', () async {
    stalled = true;
    final read = source.read('file', 0, 4).drain<void>();
    final failure = expectLater(read, throwsA(isA<SourceCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await source.dispose();
    await failure;
  });
  test('rejects a folder serving HTML or other bytes as the engine', () async {
    invalidEngine = true;
    await expectLater(
      HttpMirrorSource.discover(source.base, dataProbe: 'common/file'),
      throwsA(isA<SourceException>()),
    );
  });
}
