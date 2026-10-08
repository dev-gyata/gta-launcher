import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/server/mirror_server.dart';
import 'package:playgta5_launcher/sources/http_source.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';

class BrokenSource implements MirrorSource {
  BrokenSource(this.status);
  final int status;
  @override
  String get identity => 'broken';
  @override
  Future<SourceFile?> stat(String path) async => const SourceFile(6);
  @override
  Stream<List<int>> read(String path, int a, int b) async* {
    throw SourceException('failed', status: status);
  }

  @override
  Future<void> dispose() async {}
}

class FailingDisposeSource extends BrokenSource {
  FailingDisposeSource() : super(502);
  @override
  Future<void> dispose() async => throw StateError('disposal failed');
}

void main() {
  test(
    'serves HTTP data ranges and builds clamped gzip batches locally',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((r) async {
        final bytes = 'abcdef'.codeUnits;
        final range = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(r.headers.value('range') ?? '');
        if (range != null) {
          final a = int.parse(range[1]!), b = int.parse(range[2]!);
          r.response.statusCode = 206;
          r.response.headers.set('content-range', 'bytes $a-$b/6');
          r.response.contentLength = b - a + 1;
          r.response.add(bytes.sublist(a, b + 1));
        } else {
          r.response.contentLength = 6;
        }
        await r.response.close();
      });
      final source = HttpMirrorSource(
        Uri.parse('http://127.0.0.1:${upstream.port}/'),
      );
      final server = MirrorServer.fromSource(source);
      final url = await server.start(port: 0);
      final client = HttpClient()..autoUncompress = false;
      addTearDown(() async {
        client.close(force: true);
        await server.dispose();
        await upstream.close(force: true);
      });
      final get = await client.getUrl(url.resolve('data/file'));
      get.headers.set('range', 'bytes=1-3');
      final res = await get.close();
      expect(res.statusCode, 206);
      expect(await utf8.decoder.bind(res).join(), 'bcd');
      final req = await client.postUrl(url.resolve('data/batch?gz=1'));
      req.write(
        jsonEncode([
          ['file', 4, 99],
          ['file', 0, 1],
        ]),
      );
      final batch = await req.close();
      expect(batch.statusCode, 200);
      expect(batch.headers.value('x-run-lengths'), '2,2');
      expect(
        utf8.decode(gzip.decode(await batch.expand((b) => b).toList())),
        'efab',
      );
    },
  );
  for (final status in [502, 504]) {
    test('maps pre-body source failures to $status', () async {
      final server = MirrorServer.fromSource(BrokenSource(status));
      final url = await server.start(port: 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.dispose();
      });
      final res = await (await client.getUrl(url.resolve('file'))).close();
      expect(res.statusCode, status);
      await res.drain<void>();
    });
  }
  test('Stop closes its socket even when source disposal fails', () async {
    final server = MirrorServer.fromSource(FailingDisposeSource());
    final url = await server.start(port: 0);
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    addTearDown(() async {
      client.close(force: true);
      try {
        await server.dispose();
      } catch (_) {}
    });
    await expectLater(server.stop(), throwsStateError);
    await expectLater(
      client.getUrl(url).then((r) => r.close()),
      throwsA(isA<SocketException>()),
    );
  });
}
