import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';
import 'package:playgta5_launcher/sources/prefix_source.dart';

void main() {
  test(
    'discovers complete nested mirror roots and reads selected prefix',
    () async {
      final temp = await Directory.systemTemp.createTemp('prefix_source');
      addTearDown(() => temp.delete(recursive: true));
      await Directory(
        '${temp.path}/archive/mirror/playgta5.com/b/8b0b5899ed',
      ).create(recursive: true);
      await File(
        '${temp.path}/archive/mirror/playgta5.com/b/8b0b5899ed/game.wasm',
      ).writeAsString('wasm');
      final paths = [
        'archive/mirror/playgta5.com/b/8b0b5899ed/game.wasm',
        'archive/mirror/playgta5.com/data/file',
        'other/b/8b0b5899ed/game.wasm',
      ];
      expect(discoverMirrorRoots(paths), ['archive/mirror/playgta5.com/']);
      final source = PrefixMirrorSource(
        LocalMirrorSource(temp.path),
        'archive/mirror/playgta5.com/',
      );
      expect((await source.stat('b/8b0b5899ed/game.wasm'))!.size, 4);
      expect(await source.stat('../outside'), isNull);
      expect(
        await source
            .read('b/8b0b5899ed/game.wasm', 0, 4)
            .expand((b) => b)
            .toList(),
        [119, 97, 115, 109],
      );
      await source.dispose();
    },
  );
}
