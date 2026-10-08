import 'dart:async';
import 'dart:io';
import 'mirror_source.dart';

class HttpMirrorSource implements MirrorSource {
  HttpMirrorSource(
    Uri base, {
    SourceCancellation? cancellation,
    this.timeout = const Duration(seconds: 60),
  }) : base = _normalize(base),
       cancellation = cancellation ?? SourceCancellation() {
    _client.autoUncompress = false;
    _client.connectionTimeout = timeout;
    this.cancellation.whenCancelled.then((_) => _client.close(force: true));
  }
  final Uri base;
  final SourceCancellation cancellation;
  final Duration timeout;
  final _client = HttpClient();
  final _metadata = <String, Future<SourceFile?>>{};
  @override
  String get identity => 'http:$base';

  static Uri _normalize(Uri uri) {
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Use a public HTTP(S) folder URL without credentials, query, or fragment',
      );
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  static Future<HttpMirrorSource> discover(
    Uri url, {
    required String dataProbe,
    SourceCancellation? cancellation,
    void Function(String)? onLog,
  }) async {
    final base = _normalize(url);
    Object? lastError;
    for (final candidate in [
      base,
      base.resolve('playgta5.com/'),
      base.resolve('mirror/playgta5.com/'),
    ]) {
      cancellation?.check();
      final source = HttpMirrorSource(candidate, cancellation: cancellation);
      try {
        onLog?.call('Checking HTTP mirror $candidate');
        await validateMirrorEngine(source);
        final path = 'data/$dataProbe';
        final info = await source.stat(path);
        if (info == null || info.size == 0) {
          throw const SourceException('Required mirror data files are missing');
        }
        await source.read(path, 0, 1).drain<void>();
        return source;
      } catch (e) {
        source._client.close(force: true);
        if (e is SourceCancelled) rethrow;
        lastError = e;
      }
    }
    throw SourceException('No compatible HTTP mirror found: $lastError');
  }

  Future<HttpClientResponse> _request(
    String method,
    Uri uri, {
    String? range,
  }) async {
    cancellation.check();
    try {
      for (var redirect = 0; redirect <= 5; redirect++) {
        if (!['http', 'https'].contains(uri.scheme) ||
            uri.userInfo.isNotEmpty) {
          throw const SourceException('Invalid HTTP redirect');
        }
        final request = await cancellation.bind(
          _client.openUrl(method, uri).timeout(timeout),
        );
        request.followRedirects = false;
        request.headers.set('Accept-Encoding', 'identity');
        if (range != null) request.headers.set('Range', range);
        final response = await cancellation.bind(
          request.close().timeout(timeout),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          await response.listen((_) {}).cancel();
          if (location == null || redirect == 5) {
            throw const SourceException('Invalid or excessive HTTP redirects');
          }
          uri = uri.resolve(location);
          continue;
        }
        return response;
      }
      throw const SourceException('Excessive redirects');
    } on TimeoutException {
      throw const SourceException('HTTP mirror timed out', status: 504);
    } on SourceException {
      rethrow;
    } catch (e) {
      cancellation.check();
      throw SourceException('HTTP mirror connection failed: $e');
    }
  }

  Uri _uri(String path) =>
      base.resolve(path.split('/').map(Uri.encodeComponent).join('/'));
  @override
  Future<SourceFile?> stat(String path) async {
    cancellation.check();
    if (!safeSourcePath(path) || path.isEmpty) return null;
    final existing = _metadata[path];
    if (existing != null) return existing;
    final future = _stat(path);
    _metadata[path] = future;
    try {
      return await future;
    } catch (_) {
      _metadata.remove(path);
      rethrow;
    }
  }

  Future<SourceFile?> _stat(String path) async {
    final res = await _request('HEAD', _uri(path));
    await res.listen((_) {}).cancel();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200 || res.contentLength < 0) {
      throw SourceException(
        'Mirror must expose file sizes (HTTP ${res.statusCode})',
      );
    }
    return SourceFile(
      res.contentLength,
      modified: _date(res.headers.value('last-modified')),
    );
  }

  DateTime? _date(String? value) {
    try {
      return value == null ? null : HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    cancellation.check();
    if (!safeSourcePath(path)) {
      throw const SourceException('Invalid source path', status: 404);
    }
    if (start < 0 || end < start) {
      throw const SourceException('Invalid byte range', status: 416);
    }
    if (end == start) return;
    final res = await _request(
      'GET',
      _uri(path),
      range: 'bytes=$start-${end - 1}',
    );
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(res.headers.value('content-range') ?? '');
    final encoding = res.headers.value('content-encoding');
    if (res.statusCode != 206 ||
        match == null ||
        int.parse(match[1]!) != start ||
        int.parse(match[2]!) != end - 1 ||
        int.parse(match[3]!) < end ||
        (encoding != null && encoding != 'identity') ||
        (res.contentLength >= 0 && res.contentLength != end - start)) {
      await res.listen((_) {}).cancel();
      throw SourceException(
        'Mirror returned an invalid byte range (HTTP ${res.statusCode}); byte-range support is required',
      );
    }
    var received = 0;
    try {
      await for (final bytes in res.timeout(timeout)) {
        cancellation.check();
        received += bytes.length;
        if (received > end - start) {
          throw const SourceException('Mirror returned too many bytes');
        }
        yield bytes;
      }
      if (received != end - start) {
        throw const SourceException('Mirror response was truncated');
      }
    } on TimeoutException {
      throw const SourceException('HTTP mirror read stalled', status: 504);
    } on SourceException {
      rethrow;
    } catch (e) {
      cancellation.check();
      throw SourceException('HTTP mirror read failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    cancellation.cancel();
    _client.close(force: true);
  }
}
