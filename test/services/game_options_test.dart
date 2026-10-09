import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/services/game_options.dart';
import 'package:playgta5_launcher/ui/game_options_dialog.dart';

void main() {
  test('defaults add nothing to the game URL', () {
    final url = Uri.parse('http://localhost:8000/');
    expect(GameOptions.defaults.query, isEmpty);
    expect(GameOptions.defaults.apply(url), url);
  });

  test('each option maps to the URL option the game page reads', () {
    const o = GameOptions(
      startMode: StartMode.sandboxTestMap,
      graphics: GraphicsProfile.low,
      lowMemoryShadows: true,
      renderScale: 0.75,
      frameCap: FrameCap.fps30,
      showFps: true,
      controller: ControllerMode.keyboard,
      lookSensitivity: 1.5,
      touch: TouchControls.on,
      skipDeviceCheck: true,
    );
    expect(o.query, {
      'mode': 'sandbox',
      'map': 'env_test',
      'low': '1',
      'shadows': '1',
      'scale': '0.75',
      'fps': '30',
      'showfps': '1',
      'pad': 'keys',
      'padsens': '1.5',
      'touch': '1',
      'nocheck': '1',
    });
    expect(
      o.apply(Uri.parse('http://localhost:8000/')).toString(),
      startsWith('http://localhost:8000/?mode=sandbox&map=env_test'),
    );
  });

  test('options that do not apply are left out', () {
    expect(const GameOptions(startMode: StartMode.sandbox, newGame: true).query, {'mode': 'sandbox'});
    expect(const GameOptions(startMode: StartMode.story, newGame: true).query, {'mode': 'story', 'newgame': '1'});
    expect(const GameOptions(graphics: GraphicsProfile.full, lowMemoryShadows: true).query, {'low': '0'});
    expect(const GameOptions(controller: ControllerMode.off, frameCap: FrameCap.uncapped).query, {
      'pad': '0',
      'fps': '0',
    });
  });

  test('saves and loads, and survives bad or foreign data', () {
    const o = GameOptions(startMode: StartMode.story, renderScale: 0.6, touch: TouchControls.off);
    expect(GameOptions.fromJson(o.toJson()).query, o.query);
    expect(GameOptions.fromJson(null).query, isEmpty);
    expect(GameOptions.fromJson('not json').query, isEmpty);
    expect(GameOptions.fromJson('{"startMode":"bogus","renderScale":9,"touch":"on"}').query, {'touch': '1'});
  });

  testWidgets('the dialog edits and returns the options', (tester) async {
    GameOptions? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<GameOptions>(
              context: context,
              builder: (_) => const GameOptionsDialog(initial: GameOptions.defaults),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask on the start screen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Story Mode').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Show FPS counter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show FPS counter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result?.query, {'mode': 'story', 'showfps': '1'});
  });
}
