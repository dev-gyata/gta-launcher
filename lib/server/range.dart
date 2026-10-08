/// Parses an HTTP `Range` header the same way `serve_local.py` does.
library;

sealed class RangeResult {
  const RangeResult();
}

/// Header is malformed (`bytes=-`, garbage, multi-range).
class RangeInvalid extends RangeResult {
  const RangeInvalid();
}

/// Header parsed but the range cannot be satisfied for this file size.
class RangeUnsatisfiable extends RangeResult {
  const RangeUnsatisfiable();
}

/// Inclusive byte range `[start, end]`.
class RangeOk extends RangeResult {
  const RangeOk(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;

  @override
  bool operator ==(Object other) => other is RangeOk && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'RangeOk($start, $end)';
}

final _pattern = RegExp(r'^bytes=(\d*)-(\d*)$');

RangeResult parseRange(String header, int size) {
  final match = _pattern.firstMatch(header);
  if (match == null) return const RangeInvalid();
  final a = match[1]!, b = match[2]!;
  if (a.isEmpty && b.isEmpty) return const RangeInvalid();

  final int start;
  final int end;
  if (a.isEmpty) {
    // Suffix range: last N bytes.
    final n = int.parse(b);
    start = size - n < 0 ? 0 : size - n;
    end = size - 1;
  } else {
    start = int.parse(a);
    end = b.isEmpty ? size - 1 : (int.parse(b) < size - 1 ? int.parse(b) : size - 1);
  }
  if (start >= size || end < start) return const RangeUnsatisfiable();
  return RangeOk(start, end);
}
