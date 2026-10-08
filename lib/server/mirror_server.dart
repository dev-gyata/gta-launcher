/// Dart port of `serve_local.py`: isolation headers, byte ranges and the
/// engine's `/data/batch` I/O endpoint.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'range.dart';
import '../sources/mirror_source.dart';

const _maxBatchBody = 1024 * 1024;
const _maxBatchRuns = 1000;
const _maxBatchBytes = 64 * 1024 * 1024;

const _mimeOverrides = {
  '.wasm': 'application/wasm',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.html': 'text/html',
  '.json': 'application/json',
  '.css': 'text/css',
};

class MirrorServer {
  MirrorServer(String root, {this.bundled = const {}})
    : root = p.normalize(p.absolute(root)),
      source = LocalMirrorSource(root);

  MirrorServer.fromSource(this.source, {this.bundled = const {}})
    : root = source.identity;

  final MirrorSource source;

  /// The `playgta5.com` directory being served.
  final String root;

  /// Files served from memory instead of [root], keyed by URL path.
  final Map<String, Uint8List> bundled;

  HttpServer? _server;
  final _log = StreamController<String>.broadcast();

  Stream<String> get log => _log.stream;
  bool get isRunning => _server != null;
  int? get port => _server?.port;
  Uri? get url =>
      _server == null ? null : Uri.parse('http://localhost:${_server!.port}/');

  /// Binds to loopback on [port]; if it is taken and [fallback] is true,
  /// binds to any free port instead.
  Future<Uri> start({int port = 8000, bool fallback = true}) async {
    if (_server != null) return url!;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      if (!fallback) rethrow;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _emit('Port $port is busy, using ${server.port} instead');
    }
    server.autoCompress = false;
    server.defaultResponseHeaders.clear();
    _server = server;
    server.listen(_handle, onError: (Object e) => _emit('Server error: $e'));
    _emit('Serving $root at $url');
    return url!;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server == null) return;
    try {
      await source.dispose();
    } finally {
      await server.close(force: true);
    }
    _emit('Server stopped');
  }

  Future<void>? _disposing;
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    try {
      await stop();
    } finally {
      try {
        await source.dispose();
      } finally {
        if (!_log.isClosed) await _log.close();
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    res.headers
      ..set('Cross-Origin-Opener-Policy', 'same-origin')
      ..set('Cross-Origin-Embedder-Policy', 'require-corp')
      ..set('Cross-Origin-Resource-Policy', 'same-origin')
      ..set('Accept-Ranges', 'bytes')
      ..set('Cache-Control', 'no-store');
    try {
      switch (request.method) {
        case 'GET':
        case 'HEAD':
          await _serveFile(request);
        case 'POST':
          await _serveBatch(request);
        default:
          await _error(res, HttpStatus.notImplemented);
      }
    } catch (e) {
      _emit('${request.method} ${request.uri} failed: $e');
      try {
        await _error(
          res,
          e is SourceException ? e.status : HttpStatus.internalServerError,
          '$e',
        );
      } catch (_) {
        // Headers already sent; nothing more to do.
      }
    }
    _emit('${request.method} ${request.uri.path} ${res.statusCode}');
  }

  String? _resolve(String urlPath) {
    try {
      final path = urlPath
          .split('/')
          .where((s) => s.isNotEmpty)
          .map(Uri.decodeComponent)
          .join('/');
      return safeSourcePath(path) ? path : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _serveFile(HttpRequest request) async {
    final res = request.response;
    final urlPath = request.uri.path;
    if (urlPath == '/__launcher/source.json') {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'cacheKey': sha256.convert(utf8.encode(source.identity)).toString(),
          }),
        ),
      );
      return _serveBytes(request, bytes, 'application/json');
    }
    final bundledPath = urlPath.endsWith('/')
        ? '${urlPath}index.html'
        : urlPath;
    final memory = bundled[bundledPath];
    if (memory != null) {
      return _serveBytes(request, memory, _contentType(bundledPath));
    }
    var path = _resolve(urlPath);
    if (path == null) return _error(res, HttpStatus.notFound);
    var info = await source.stat(path);
    if (info?.isDirectory ?? false) {
      if (!urlPath.endsWith('/')) {
        res.statusCode = HttpStatus.movedPermanently;
        res.headers.set(
          'Location',
          '$urlPath/${request.uri.hasQuery ? '?${request.uri.query}' : ''}',
        );
        res.headers.contentLength = 0;
        return res.close();
      }
      path = path.isEmpty ? 'index.html' : '$path/index.html';
      info = await source.stat(path);
    }
    if (info == null || info.isDirectory) {
      return _error(res, HttpStatus.notFound);
    }
    if (info.modified != null) {
      res.headers.set('Last-Modified', HttpDate.format(info.modified!));
    }
    final range = await _applyRange(request, info.size);
    if (range == null) return;
    final (start, end) = range;
    res.headers.set('Content-Type', _contentType(path));
    if (request.method == 'HEAD' || info.size == 0) {
      res.headers.contentLength = info.size == 0 ? 0 : end - start + 1;
      return res.close();
    }
    // Resolve remote/extraction failures before committing the response headers.
    final reader = StreamIterator(source.read(path, start, end + 1));
    try {
      if (!await reader.moveNext()) {
        throw const SourceException('Source response was empty');
      }
      res.headers.contentLength = end - start + 1;
      var sent = 0;
      do {
        sent += reader.current.length;
        if (sent > end - start + 1) {
          throw const SourceException('Source returned excess bytes');
        }
        res.add(reader.current);
        await res.flush();
      } while (await reader.moveNext());
      if (sent != end - start + 1) {
        throw const SourceException('Source response was truncated');
      }
      await res.close();
    } finally {
      await reader.cancel();
    }
  }

  Future<void> _serveBytes(
    HttpRequest request,
    Uint8List bytes,
    String contentType,
  ) async {
    final res = request.response;
    final range = await _applyRange(request, bytes.length);
    if (range == null) return;
    final (start, end) = range;
    res.headers.set('Content-Type', contentType);
    res.headers.contentLength = bytes.isEmpty ? 0 : end - start + 1;
    if (request.method != 'HEAD' && bytes.isNotEmpty) {
      res.add(Uint8List.sublistView(bytes, start, end + 1));
    }
    await res.close();
  }

  /// Sets the status (and Content-Range) for [request] against a body of
  /// [size] bytes and returns the inclusive range to send, or null after
  /// already answering with an error.
  Future<(int, int)?> _applyRange(HttpRequest request, int size) async {
    final res = request.response;
    final rangeHeader = request.headers.value('range');
    if (rangeHeader == null) {
      res.statusCode = HttpStatus.ok;
      return (0, size - 1);
    }
    switch (parseRange(rangeHeader, size)) {
      case RangeInvalid():
        await _error(res, HttpStatus.requestedRangeNotSatisfiable);
        return null;
      case RangeUnsatisfiable():
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set('Content-Range', 'bytes */$size');
        res.headers.contentLength = 0;
        await res.close();
        return null;
      case RangeOk(:final start, :final end):
        res.statusCode = HttpStatus.partialContent;
        res.headers.set('Content-Range', 'bytes $start-$end/$size');
        return (start, end);
    }
  }

  Future<void> _serveBatch(HttpRequest request) async {
    final res = request.response;
    if (request.uri.path != '/data/batch') {
      return _error(res, HttpStatus.notFound);
    }
    if (request.contentLength > _maxBatchBody) {
      return _error(res, HttpStatus.requestEntityTooLarge);
    }

    final List<(String, int, int)> selected;
    try {
      final body = await _readBody(request, _maxBatchBody);
      final runs = jsonDecode(utf8.decode(body));
      if (runs is! List || runs.length > _maxBatchRuns) {
        throw const FormatException('invalid batch');
      }
      selected = [];
      var total = 0;
      for (final run in runs) {
        if (run is! List ||
            run.length != 3 ||
            run[0] is! String ||
            run[1] is! int ||
            run[2] is! int) {
          throw const FormatException('invalid run');
        }
        final name = run[0] as String,
            start = run[1] as int,
            end = run[2] as int;
        final path = 'data/$name';
        if (!safeSourcePath(name) || name.isEmpty || start < 0 || end < start) {
          throw const FormatException('invalid file/range');
        }
        final info = await source.stat(path);
        if (info == null || info.isDirectory) {
          throw const FormatException('missing batch file');
        }
        final size = info.size;
        final upper = end + 1 < size ? end + 1 : size;
        final n = upper - start > 0 ? upper - start : 0;
        selected.add((path, start, n));
        total += n;
      }
      if (total > _maxBatchBytes) {
        throw const FormatException('batch exceeds 64 MiB');
      }
    } on FormatException catch (e) {
      return _error(res, HttpStatus.badRequest, e.message);
    } on FileSystemException catch (e) {
      return _error(res, HttpStatus.badRequest, e.message);
    }

    final output = BytesBuilder(copy: false);
    for (final (path, start, n) in selected) {
      if (n == 0) continue;
      var received = 0;
      await for (final chunk in source.read(path, start, start + n)) {
        received += chunk.length;
        if (received > n) {
          throw const SourceException('Batch source returned excess bytes');
        }
        output.add(chunk);
      }
      if (received != n) {
        throw const SourceException('Batch source response was truncated');
      }
    }
    List<int> body = output.takeBytes();
    final compressed = request.uri.queryParametersAll['gz']?.join(',') == '1';
    if (compressed) body = GZipCodec(level: 1).encode(body);

    res.statusCode = HttpStatus.ok;
    res.headers
      ..set('Content-Type', 'application/octet-stream')
      ..set('X-Run-Lengths', selected.map((r) => r.$3).join(','));
    if (compressed) res.headers.set('Content-Encoding', 'gzip');
    res.headers.contentLength = body.length;
    res.add(body);
    await res.close();
  }

  void _emit(String line) {
    if (!_log.isClosed) _log.add(line);
  }

  Future<List<int>> _readBody(HttpRequest request, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > limit) throw const FormatException('body too large');
    }
    return builder.takeBytes();
  }

  String _contentType(String path) {
    final ext = p.extension(path).toLowerCase();
    return _mimeOverrides[ext] ??
        lookupMimeType(path) ??
        'application/octet-stream';
  }

  Future<void> _error(HttpResponse res, int status, [String? message]) async {
    final body = utf8.encode('$status ${message ?? ''}'.trim());
    res.statusCode = status;
    res.headers.set('Content-Type', 'text/plain; charset=utf-8');
    res.headers.contentLength = body.length;
    res.add(body);
    await res.close();
  }
}
