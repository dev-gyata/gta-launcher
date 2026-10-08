import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/server/mirror_server.dart';

void main() {
  test(
    'cache identity is stable per source and distinct between sources',
    () async {
      final a = await Directory.systemTemp.createTemp('cache_a');
      final b = await Directory.systemTemp.createTemp('cache_b');
      final first = MirrorServer(a.path), second = MirrorServer(b.path);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await first.dispose();
        await second.dispose();
        await a.delete();
        await b.delete();
      });
      final url1 = await first.start(port: 0),
          url2 = await second.start(port: 0);
      Future<String> id(Uri url) async {
        final res = await (await client.getUrl(
          url.resolve('__launcher/source.json'),
        )).close();
        expect(res.statusCode, 200);
        expect(res.headers.value('cache-control'), 'no-store');
        return (jsonDecode(await utf8.decoder.bind(res).join())
                as Map)['cacheKey']
            as String;
      }

      final key = await id(url1);
      expect(key, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(await id(url1), key);
      expect(await id(url2), isNot(key));
    },
  );
}
