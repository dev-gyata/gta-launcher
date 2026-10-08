import 'dart:io';

import 'package:path/path.dart' as p;

import '../server/site_files.dart';

/// Finds the servable site root inside whatever folder the user picked.
///
/// Accepts the site root itself (`.../playgta5.com`), the `mirror` folder
/// containing it, or the folder containing `mirror/playgta5.com`. The site
/// files ship with the launcher, so only the engine (`game.wasm`) and the
/// `data/` folder have to come from the mirror. Returns null if not found.
String? resolveMirrorRoot(String picked) {
  final candidates = [picked, p.join(picked, 'playgta5.com'), p.join(picked, 'mirror', 'playgta5.com')];
  final wasm = p.joinAll(p.url.split('$buildPath/game.wasm').skip(1));
  for (final dir in candidates) {
    if (File(p.join(dir, wasm)).existsSync() && Directory(p.join(dir, 'data')).existsSync()) {
      return p.normalize(dir);
    }
  }
  return null;
}
