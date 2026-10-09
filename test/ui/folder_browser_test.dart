import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:playgta5_launcher/server/site_files.dart';
import 'package:playgta5_launcher/ui/folder_browser.dart';

void main() {
  late Directory storage;

  setUp(() {
    storage = Directory.systemTemp.createTempSync('folder_browser');
    final mirror = p.join(storage.path, 'Download', 'mirror', 'playgta5.com');
    Directory(p.join(mirror, 'data')).createSync(recursive: true);
    final wasm = File(p.joinAll([mirror, ...p.url.split('$buildPath/game.wasm').skip(1)]));
    wasm.parent.createSync(recursive: true);
    wasm.writeAsBytesSync([0, 97, 115, 109]);
    Directory(p.join(storage.path, 'Music')).createSync();
    Directory(p.join(storage.path, '.hidden')).createSync();
  });

  tearDown(() => storage.deleteSync(recursive: true));

  Future<String?> pick(WidgetTester tester, Future<void> Function() steps) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await Navigator.of(context).push<String>(
              MaterialPageRoute(builder: (_) => FolderBrowser(roots: [storage.path])),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await steps();
    return picked;
  }

  testWidgets('walks into folders, recognises the mirror and returns its path', (tester) async {
    final picked = await pick(tester, () async {
      expect(find.text('Internal storage'), findsOneWidget);
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('.hidden'), findsNothing);
      expect(find.text('..'), findsNothing);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('mirror'));
      await tester.pumpAndSettle();
      expect(find.text('Mirror found: use this folder'), findsOneWidget);
      await tester.tap(find.byKey(const Key('use-folder')));
      await tester.pumpAndSettle();
    });
    expect(picked, p.join(storage.path, 'Download', 'mirror'));
  });

  testWidgets('goes back up and closing returns nothing', (tester) async {
    final picked = await pick(tester, () async {
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();
      expect(find.text('Mirror found: use this folder'), findsNothing);
      await tester.tap(find.text('..'));
      await tester.pumpAndSettle();
      expect(find.text('Download'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
    });
    expect(picked, isNull);
  });
}
