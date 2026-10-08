import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/services/settings.dart';
import 'package:playgta5_launcher/services/source_manager.dart';
import 'package:playgta5_launcher/sources/mirror_source.dart';
import 'package:playgta5_launcher/sources/source_selection.dart';
import 'package:playgta5_launcher/ui/launcher_page.dart';
import 'fakes.dart';

class PendingManager extends SourceManager {
  SourceCancellation? cancellation;
  final completed = Completer<MirrorSource>();
  bool clearCalled = false;
  bool cancelOnFailure = false;
  Future<String?> Function(List<String>)? chooseRoot;
  @override
  Future<MirrorSource> open(
    SourceKind kind,
    String value, {
    required SourceCancellation cancellation,
    void Function(String)? onLog,
    Future<String?> Function(List<String>)? chooseRoot,
  }) {
    this.cancellation = cancellation;
    this.chooseRoot = chooseRoot;
    onLog?.call('Reading metadata');
    return completed.future.catchError((Object error) {
      if (cancelOnFailure) cancellation.cancel();
      throw error;
    });
  }

  @override
  Future<int> cacheBytes() async => clearCalled ? 0 : 2048;
  @override
  Future<void> clearCache() async {
    clearCalled = true;
  }
}

class DisposableSource implements MirrorSource {
  bool disposed = false;
  @override
  String get identity => 'test-source';
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<SourceFile?> stat(String path) async => null;
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

Future<Settings> pumpLauncher(
  WidgetTester tester,
  PendingManager manager,
) async {
  final settings = Settings(MemoryPreferences());
  await tester.pumpWidget(
    MaterialApp(
      home: LauncherPage(
        settings: settings,
        inApp: BrowserSupport(),
        sourceManager: manager,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  testWidgets(
    'remote input survives source switches and cache can be cleared',
    (tester) async {
      final manager = PendingManager();
      final settings = await pumpLauncher(tester, manager);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('source-input')),
        'https://example.com/game/',
      );
      await tester.tap(find.text('Magnet'));
      await tester.pumpAndSettle();
      expect(
        await settings.sourceValue(SourceKind.http),
        'https://example.com/game/',
      );
      await tester.enterText(
        find.byKey(const Key('source-input')),
        'magnet:?xt=urn:btih:abc',
      );
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/game/'), findsOneWidget);
      await tester.tap(find.text('Clear torrent cache'));
      await tester.pumpAndSettle();
      expect(find.text('Torrent cache: 0 B'), findsOneWidget);
    },
  );

  testWidgets('Stop cancels preparation and Start waits for cleanup', (
    tester,
  ) async {
    final manager = PendingManager();
    await pumpLauncher(tester, manager);
    await tester.tap(find.text('HTTP'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('source-input')),
      'https://example.com/game/',
    );
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Reading metadata'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(manager.cancellation!.cancelled, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNull,
    );
    manager.completed.completeError(const SourceCancelled());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNotNull,
    );
    expect(find.textContaining('Could not start'), findsNothing);
  });

  testWidgets('source preparation errors leave launcher usable', (
    tester,
  ) async {
    final manager = PendingManager()..cancelOnFailure = true;
    await pumpLauncher(tester, manager);
    await tester.tap(find.text('Magnet'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('source-input')),
      'invalid magnet',
    );
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();
    manager.completed.completeError(
      const SourceException('Invalid magnet link'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Invalid magnet link'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'a source completing after Stop is disposed instead of launched',
    (tester) async {
      final manager = PendingManager();
      await pumpLauncher(tester, manager);
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('source-input')),
        'https://example.com/game/',
      );
      await tester.pump();
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Stop'));
      await tester.pump();
      final source = DisposableSource();
      manager.completed.complete(source);
      await tester.pumpAndSettle();
      expect(source.disposed, isTrue);
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('Open in browser'), findsNothing);
    },
  );

  testWidgets('root selection closes when startup cancellation fires', (
    tester,
  ) async {
    final manager = PendingManager();
    await pumpLauncher(tester, manager);
    await tester.tap(find.text('Magnet'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('source-input')),
      'magnet:?xt=urn:btih:abc',
    );
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();
    final selection = manager.chooseRoot!([
      'first/root',
      'archive.zip :: second/root',
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Choose a mirror'), findsOneWidget);
    manager.cancellation!.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(await selection, isNull);
    expect(find.text('Choose a mirror'), findsNothing);
    manager.completed.completeError(const SourceCancelled());
    await tester.pumpAndSettle();
  });

  testWidgets('widget disposal cancels startup and removes root selection', (
    tester,
  ) async {
    final manager = PendingManager();
    await pumpLauncher(tester, manager);
    await tester.tap(find.text('Magnet'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('source-input')),
      'magnet:?xt=urn:btih:abc',
    );
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump();
    final selection = manager.chooseRoot!(['first', 'second']);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(manager.cancellation!.cancelled, isTrue);
    expect(await selection, isNull);
    final source = DisposableSource();
    manager.completed.complete(source);
    await tester.pumpAndSettle();
    expect(source.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('source controls fit the minimum launcher window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpLauncher(tester, PendingManager());
    await tester.tap(find.text('Magnet'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('source-input')),
      'magnet:?xt=urn:btih:abc&tr=${'https://tracker.example.com/'.padRight(500, 'x')}',
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Start').hitTestable(), findsOneWidget);
  });
}
