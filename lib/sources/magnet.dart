class MagnetLink {
  const MagnetLink(this.uri, this.hash);
  final Uri uri;
  final String hash;
}

MagnetLink parseMagnet(String input) {
  final text = input.trim().replaceAllMapped(
    RegExp(r'\[([^\]\r\n]*)\]\([^\)\r\n]*\)'),
    (m) => m[1]!,
  );
  if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(text)) {
    throw const FormatException('Invalid percent encoding in magnet link');
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'magnet' ||
      uri.hasAuthority ||
      uri.path.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('Enter a magnet:?xt=… link');
  }
  final topics = uri.queryParametersAll['xt'] ?? [];
  for (final topic in topics) {
    if (topic.startsWith('urn:btih:')) {
      final hash = topic.substring(9);
      if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(hash)) {
        return MagnetLink(uri, hash.toLowerCase());
      }
      if (RegExp(r'^[A-Za-z2-7]{32}$').hasMatch(hash)) {
        const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        var bits = 0, value = 0;
        final bytes = <int>[];
        for (final char in hash.toUpperCase().split('')) {
          value = (value << 5) | alphabet.indexOf(char);
          bits += 5;
          if (bits >= 8) {
            bits -= 8;
            bytes.add((value >> bits) & 255);
            value &= (1 << bits) - 1;
          }
        }
        return MagnetLink(
          uri,
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        );
      }
    }
    if (RegExp(r'^urn:btmh:1220[0-9a-fA-F]{64}$').hasMatch(topic)) {
      return MagnetLink(uri, topic.substring(9).toLowerCase());
    }
  }
  throw const FormatException('Magnet link needs a valid BitTorrent info hash');
}
