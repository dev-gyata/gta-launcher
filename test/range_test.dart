import 'package:flutter_test/flutter_test.dart';
import 'package:playgta5_launcher/server/range.dart';

void main() {
  test('explicit range', () => expect(parseRange('bytes=0-99', 1000), const RangeOk(0, 99)));
  test('end clamped to size', () => expect(parseRange('bytes=900-5000', 1000), const RangeOk(900, 999)));
  test('open-ended range', () => expect(parseRange('bytes=10-', 1000), const RangeOk(10, 999)));
  test('suffix range', () => expect(parseRange('bytes=-100', 1000), const RangeOk(900, 999)));
  test('suffix larger than file', () => expect(parseRange('bytes=-5000', 1000), const RangeOk(0, 999)));
  test('empty range is invalid', () => expect(parseRange('bytes=-', 1000), isA<RangeInvalid>()));
  test('garbage is invalid', () => expect(parseRange('items=0-1', 1000), isA<RangeInvalid>()));
  test('multi-range is invalid', () => expect(parseRange('bytes=0-1,5-6', 1000), isA<RangeInvalid>()));
  test('start past end of file', () => expect(parseRange('bytes=1000-', 1000), isA<RangeUnsatisfiable>()));
  test('end before start', () => expect(parseRange('bytes=50-10', 1000), isA<RangeUnsatisfiable>()));
  test('zero-length suffix', () => expect(parseRange('bytes=-0', 1000), isA<RangeUnsatisfiable>()));
}
