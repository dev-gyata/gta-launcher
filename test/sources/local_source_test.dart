import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';

void main() {
  test(
    'local source reads ranges and prevents traversal and escaping symlinks',
    () async {
      final dir = await Directory.systemTemp.createTemp('local_source');
      final outside = await Directory.systemTemp.createTemp('outside_source');
      addTearDown(() async {
        await dir.delete(recursive: true);
        await outside.delete(recursive: true);
      });
      await File('${dir.path}/file').writeAsString('abcdef');
      await File('${outside.path}/secret').writeAsString('secret');
      await Link('${dir.path}/escape').create(outside.path);
      final source = LocalMirrorSource(dir.path);
      expect((await source.stat('file'))!.size, 6);
      expect(await source.read('file', 1, 4).expand((b) => b).toList(), [
        98,
        99,
        100,
      ]);
      expect(await source.stat('../secret'), isNull);
      expect(await source.stat('escape/secret'), isNull);
      await source.dispose();
    },
  );
}
