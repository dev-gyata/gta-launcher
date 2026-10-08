import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/server/site_files.dart';

void main() {
  test('every bundled site file exists in site/', () async {
    final site = await loadSiteFiles((name) => File('site/$name').readAsBytes());
    expect(site.keys, unorderedEquals(siteFiles.keys));
    for (final entry in site.entries) {
      expect(entry.value, isNotEmpty, reason: entry.key);
    }
  });
}
