import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playgta5_launcher/server/mirror_server.dart';
import 'package:playgta5_launcher/server/site_files.dart';
import 'package:playgta5_launcher/services/mirror_validator.dart';

void main() {
  late Directory temp;
  late String root;
  late MirrorServer server;
  late Uri base;
  final client = HttpClient()..autoUncompress = false;
  final blob = List<int>.generate(1000, (i) => i % 256);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mirror_test');
    root = p.join(temp.path, 'mirror', 'playgta5.com');
    await Directory(p.join(root, 'data')).create(recursive: true);
    await Directory(p.join(root, 'sub')).create();
    await File(p.join(root, 'index.html')).writeAsString('<h1>hi</h1>');
    await File(p.join(root, 'engine.wasm')).writeAsBytes([0, 97, 115, 109]);
    await Directory(p.join(root, 'b', '8b0b5899ed')).create(recursive: true);
    await File(p.join(root, 'b', '8b0b5899ed', 'game.wasm')).writeAsBytes([0, 97, 115, 109]);
    await File(p.join(root, 'b', '8b0b5899ed', 'game.js')).writeAsString('mirror copy');
    await File(p.join(root, 'data', 'a.bin')).writeAsBytes(blob);
    await File(p.join(temp.path, 'secret.txt')).writeAsString('nope');
    server = MirrorServer(
      root,
      bundled: {
        '/index.html': Uint8List.fromList(utf8.encode('<h1>bundled</h1>')),
        '$buildPath/game.js': Uint8List.fromList(utf8.encode('bundled game.js')),
      },
    );
    base = await server.start(port: 0);
  });

  tearDown(() async {
    await server.dispose();
    await temp.delete(recursive: true);
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final req = await client.openUrl(method, base.resolve(path));
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    if (body != null) req.write(body);
    return req.close();
  }

  Future<List<int>> bytes(HttpClientResponse r) => r.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));

  test('serves index with isolation headers', () async {
    final r = await send('GET', '/');
    expect(r.statusCode, 200);
    expect(r.headers.value('cross-origin-opener-policy'), 'same-origin');
    expect(r.headers.value('cross-origin-embedder-policy'), 'require-corp');
    expect(r.headers.value('cross-origin-resource-policy'), 'same-origin');
    expect(r.headers.value('accept-ranges'), 'bytes');
    expect(r.headers.contentType?.mimeType, 'text/html');
    expect(utf8.decode(await bytes(r)), '<h1>bundled</h1>');
  });

  test('bundled files take precedence and support ranges', () async {
    var r = await send('GET', '$buildPath/game.js');
    expect(r.headers.contentType?.mimeType, 'text/javascript');
    expect(utf8.decode(await bytes(r)), 'bundled game.js');
    r = await send('GET', '$buildPath/game.js', headers: {'Range': 'bytes=0-6'});
    expect(r.statusCode, 206);
    expect(r.headers.value('content-range'), 'bytes 0-6/15');
    expect(utf8.decode(await bytes(r)), 'bundled');
  });

  test('non-bundled files come from the mirror', () async {
    final r = await send('GET', '$buildPath/game.wasm');
    expect(r.statusCode, 200);
    expect(await bytes(r), [0, 97, 115, 109]);
  });

  test('wasm mime type', () async {
    final r = await send('GET', '/engine.wasm');
    expect(r.headers.contentType?.mimeType, 'application/wasm');
    await bytes(r);
  });

  test('redirects directories without trailing slash', () async {
    final r = await send('GET', '/sub');
    expect(r.statusCode, 301);
    expect(r.headers.value('location'), '/sub/');
    await bytes(r);
  });

  test('range returns 206', () async {
    final r = await send('GET', '/data/a.bin', headers: {'Range': 'bytes=10-19'});
    expect(r.statusCode, 206);
    expect(r.headers.value('content-range'), 'bytes 10-19/1000');
    expect(await bytes(r), blob.sublist(10, 20));
  });

  test('unsatisfiable range returns 416 with size', () async {
    final r = await send('GET', '/data/a.bin', headers: {'Range': 'bytes=5000-'});
    expect(r.statusCode, 416);
    expect(r.headers.value('content-range'), 'bytes */1000');
    await bytes(r);
  });

  test('HEAD has no body', () async {
    final r = await send('HEAD', '/data/a.bin');
    expect(r.statusCode, 200);
    expect(r.contentLength, 1000);
    expect(await bytes(r), isEmpty);
  });

  test('path traversal is rejected', () async {
    final r = await send('GET', '/..%2F..%2Fsecret.txt');
    expect(r.statusCode, 404);
    await bytes(r);
  });

  test('batch concatenates runs', () async {
    final r = await send(
      'POST',
      '/data/batch',
      body: jsonEncode([
        ['a.bin', 0, 4],
        ['a.bin', 998, 5000],
      ]),
    );
    expect(r.statusCode, 200);
    expect(r.headers.value('x-run-lengths'), '5,2');
    expect(await bytes(r), [...blob.sublist(0, 5), ...blob.sublist(998)]);
  });

  test('batch gzip', () async {
    final r = await send(
      'POST',
      '/data/batch?gz=1',
      body: jsonEncode([
        ['a.bin', 0, 99],
      ]),
    );
    expect(r.headers.value('content-encoding'), 'gzip');
    expect(gzip.decode(await bytes(r)), blob.sublist(0, 100));
  });

  test('batch rejects escaping data dir', () async {
    final r = await send(
      'POST',
      '/data/batch',
      body: jsonEncode([
        ['../index.html', 0, 1],
      ]),
    );
    expect(r.statusCode, 400);
    await bytes(r);
  });

  test('batch rejects missing file and bad json', () async {
    for (final body in [
      jsonEncode([
        ['nope.bin', 0, 1],
      ]),
      '{oops',
      jsonEncode({'a': 1}),
    ]) {
      final r = await send('POST', '/data/batch', body: body);
      expect(r.statusCode, 400, reason: body);
      await bytes(r);
    }
  });

  test('POST elsewhere is 404', () async {
    final r = await send('POST', '/other', body: '[]');
    expect(r.statusCode, 404);
    await bytes(r);
  });

  test('validator accepts any folder level', () {
    for (final picked in [temp.path, p.join(temp.path, 'mirror'), root]) {
      expect(resolveMirrorRoot(picked), p.normalize(root), reason: picked);
    }
    expect(resolveMirrorRoot(p.join(root, 'data')), isNull);
  });
}
