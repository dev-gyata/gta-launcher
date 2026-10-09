// On a device or simulator: starts the launcher against an HTTP mirror and reports what the embedded webview offers the game
// (cross-origin isolation, needed for its shared memory, and WebGPU). Run with a mirror served on the host, e.g.
//   dart run tool/serve.dart <mirror> 8124
//   flutter test integration_test/game_page_webview_test.dart -d <simulator> --dart-define=MIRROR_URL=http://localhost:8124/
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:playgta5_launcher/main.dart';
import 'package:playgta5_launcher/services/in_app_support.dart';
import 'package:playgta5_launcher/services/settings.dart';

const mirrorUrl = String.fromEnvironment('MIRROR_URL', defaultValue: 'http://localhost:8124/');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the game page webview is cross-origin isolated', (tester) async {
    await tester.pumpWidget(LauncherApp(settings: Settings.create(), inApp: await InAppSupport.detect()));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('HTTP'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byKey(const Key('source-input')), mirrorUrl);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Start'));
    final report = find.textContaining('Webview: ', skipOffstage: false);
    for (var i = 0; i < 120 && report.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(report, findsOneWidget, reason: 'the game page did not report its webview');
    final line = (report.evaluate().single.widget as Text).data!;
    debugPrint('WEBVIEW REPORT: $line');
    expect(line, contains('cross-origin isolated'));
    expect(line, isNot(contains('NOT cross-origin isolated')));
  });
}
