import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/sources/magnet.dart';

void main() {
  test('normalizes sample Markdown without visiting embedded URLs', () {
    const pasted =
        'magnet:?xt=urn:btih:57a4193cc3d3f069ce436fcda040ed4c705b76c7&dn=[GTA5Webport.zip](https://gta5webport.zip/)&tr=udp%3A%2F%[2Ftracker.opentrackr.org](https://2ftracker.opentrackr.org/)%3A1337%2Fannounce&tr=udp%3A%2F%[2Fopen.stealth.si](https://2fopen.stealth.si/)%3A80%2Fannounce&tr=udp%3A%2F%[2Ftracker.torrent.eu.org](https://2ftracker.torrent.eu.org/)%3A451%2Fannounce&tr=udp%3A%2F%[2Fopen.demonii.com](https://2fopen.demonii.com/)%3A1337%2Fannounce&tr=udp%3A%2F%[2Fexodus.desync.com](https://2fexodus.desync.com/)%3A6969%2Fannounce&tr=http%3A%2F%[2Ftracker2.dler.org](https://2ftracker2.dler.org/)%3A80%2Fannounce&tr=http%3A%2F%[2Ftracker.dler.com](https://2ftracker.dler.com/)%3A6969%2Fannounce';
    final magnet = parseMagnet(pasted);
    expect(magnet.hash, '57a4193cc3d3f069ce436fcda040ed4c705b76c7');
    expect(magnet.uri.queryParameters['dn'], 'GTA5Webport.zip');
    expect(magnet.uri.queryParametersAll['tr'], [
      'udp://tracker.opentrackr.org:1337/announce',
      'udp://open.stealth.si:80/announce',
      'udp://tracker.torrent.eu.org:451/announce',
      'udp://open.demonii.com:1337/announce',
      'udp://exodus.desync.com:6969/announce',
      'http://tracker2.dler.org:80/announce',
      'http://tracker.dler.com:6969/announce',
    ]);
  });
  test('rejects absent hashes, other schemes and malformed encoding', () {
    for (final value in [
      'https://example.com/',
      'magnet:?dn=file',
      'magnet:?xt=urn:btih:bad',
      'magnet:?xt=urn:btih:57a4193cc3d3f069ce436fcda040ed4c705b76c7&tr=%ZZ',
    ]) {
      expect(() => parseMagnet(value), throwsFormatException);
    }
  });
}
