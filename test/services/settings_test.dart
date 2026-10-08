import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/services/settings.dart';
import 'package:playgta5_launcher/sources/source_selection.dart';
import '../ui/fakes.dart';

void main() {
  test('existing mirror folder remains the default local source', () async {
    final prefs = MemoryPreferences()..values['mirror_path'] = '/old/mirror';
    final settings = Settings(prefs);
    expect(await settings.sourceKind(), SourceKind.local);
    expect(await settings.sourceValue(SourceKind.local), '/old/mirror');
    expect(await settings.sourceValue(SourceKind.http), isNull);
  });
  test(
    'source values survive switching without overwriting other modes',
    () async {
      final settings = Settings(MemoryPreferences());
      await settings.setSourceValue(SourceKind.local, '/new/mirror');
      await settings.setSourceValue(
        SourceKind.http,
        'https://example.com/game/',
      );
      await settings.setSourceValue(
        SourceKind.magnet,
        'magnet:?xt=urn:btih:abc',
      );
      await settings.setSourceKind(SourceKind.magnet);
      expect(await settings.sourceKind(), SourceKind.magnet);
      expect(await settings.mirrorPath(), '/new/mirror');
      expect(
        await settings.sourceValue(SourceKind.http),
        'https://example.com/game/',
      );
      expect(
        await settings.sourceValue(SourceKind.magnet),
        'magnet:?xt=urn:btih:abc',
      );
      await settings.setMirrorPath('/compat/mirror');
      expect(await settings.sourceValue(SourceKind.local), '/compat/mirror');
    },
  );
  test('unknown saved source mode falls back to local', () async {
    final prefs = MemoryPreferences()..values['source_kind'] = 'removed';
    expect(await Settings(prefs).sourceKind(), SourceKind.local);
  });
}
