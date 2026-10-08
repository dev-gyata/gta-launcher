// Runs the launcher's server headless: dart run tool/serve.dart <root> [port]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:playgta5_launcher/server/mirror_server.dart';
import 'package:playgta5_launcher/server/site_files.dart';

Future<void> main(List<String> args) async {
  final siteDir = p.join(p.dirname(p.dirname(Platform.script.toFilePath())), 'site');
  final site = await loadSiteFiles((name) => File(p.join(siteDir, name)).readAsBytes());
  final server = MirrorServer(args[0], bundled: site);
  server.log.listen(print);
  await server.start(port: args.length > 1 ? int.parse(args[1]) : 8000, fallback: false);
}
