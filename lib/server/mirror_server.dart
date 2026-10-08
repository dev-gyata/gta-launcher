/// Dart port of `serve_local.py`: isolation headers, byte ranges and the
/// engine's `/data/batch` I/O endpoint.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'range.dart';

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
  MirrorServer(String root, {this.bundled = const {}}) : root = p.normalize(p.absolute(root));

  /// The `playgta5.com` directory being served.
  final String root;

  /// Files served from memory instead of [root], keyed by URL path.
  final Map<String, Uint8List> bundled;

  HttpServer? _server;
  final _log = StreamController<String>.broadcast();

  Stream<String> get log => _log.stream;
  bool get isRunning => _server != null;
  int? get port => _server?.port;
  Uri? get url => _server == null ? null : Uri.parse('http://localhost:${_server!.port}/');

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
      _log.add('Port $port is busy, using ${server.port} instead');
    }
    server.autoCompress = false;
    server.defaultResponseHeaders.clear();
    _server = server;
    server.listen(_handle, onError: (Object e) => _log.add('Server error: $e'));
    _log.add('Serving $root at $url');
    return url!;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server == null) return;
    await server.close(force: true);
    _log.add('Server stopped');
  }

  Future<void> dispose() async {
    await stop();
    await _log.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    res.headers
      ..set('Cross-Origin-Opener-Policy', 'same-origin')
      ..set('Cross-Origin-Embedder-Policy', 'require-corp')
      ..set('Cross-Origin-Resource-Policy', 'same-origin')
      ..set('Accept-Ranges', 'bytes');
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
      _log.add('${request.method} ${request.uri} failed: $e');
      try {
        await _error(res, HttpStatus.internalServerError);
      } catch (_) {
        // Headers already sent; nothing more to do.
      }
    }
    _log.add('${request.method} ${request.uri.path} ${res.statusCode}');
  }

  /// Maps a URL path to a file under [root], or null if it escapes it.
  String? _resolve(String urlPath) {
    final segments = urlPath.split('/').where((s) => s.isNotEmpty).map(Uri.decodeComponent);
    final resolved = p.normalize(p.joinAll([root, ...segments]));
    if (resolved != root && !p.isWithin(root, resolved)) return null;
    return resolved;
  }

  Future<void> _serveFile(HttpRequest request) async {
    final res = request.response;
    final urlPath = request.uri.path;
    final bundledPath = urlPath.endsWith('/') ? '${urlPath}index.html' : urlPath;
    final memory = bundled[bundledPath];
    if (memory != null) return _serveBytes(request, memory, _contentType(bundledPath));

    var path = _resolve(urlPath);
    if (path == null) return _error(res, HttpStatus.notFound);

    if (await FileSystemEntity.isDirectory(path)) {
      if (!urlPath.endsWith('/')) {
        res.statusCode = HttpStatus.movedPermanently;
        res.headers.set('Location', '$urlPath/${request.uri.hasQuery ? '?${request.uri.query}' : ''}');
        res.headers.contentLength = 0;
        return res.close();
      }
      path = p.join(path, 'index.html');
    }

    final file = File(path);
    if (!await file.exists()) return _error(res, HttpStatus.notFound);
    res.headers.set('Last-Modified', HttpDate.format(await file.lastModified()));
    final size = await file.length();
    final range = await _applyRange(request, size);
    if (range == null) return;
    final (start, end) = range;
    res.headers.set('Content-Type', _contentType(path));
    res.headers.contentLength = size == 0 ? 0 : end - start + 1;
    if (request.method == 'HEAD' || size == 0) return res.close();
    await res.addStream(file.openRead(start, end + 1));
    await res.close();
  }

  Future<void> _serveBytes(HttpRequest request, Uint8List bytes, String contentType) async {
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
    if (request.uri.path != '/data/batch') return _error(res, HttpStatus.notFound);
    if (request.contentLength > _maxBatchBody) {
      return _error(res, HttpStatus.requestEntityTooLarge);
    }

    final List<(File, int, int)> selected;
    try {
      final body = await _readBody(request, _maxBatchBody);
      final runs = jsonDecode(utf8.decode(body));
      if (runs is! List || runs.length > _maxBatchRuns) {
        throw const FormatException('invalid batch');
      }
      final dataRoot = p.join(root, 'data');
      selected = [];
      var total = 0;
      for (final run in runs) {
        if (run is! List || run.length != 3 || run[0] is! String || run[1] is! int || run[2] is! int) {
          throw const FormatException('invalid run');
        }
        final name = run[0] as String, start = run[1] as int, end = run[2] as int;
        final path = p.normalize(p.join(dataRoot, name));
        if (!p.isWithin(dataRoot, path) || start < 0 || end < start) {
          throw const FormatException('invalid file/range');
        }
        final file = File(path);
        final size = file.lengthSync(); // throws FileSystemException if missing
        final upper = end + 1 < size ? end + 1 : size;
        final n = upper - start > 0 ? upper - start : 0;
        selected.add((file, start, n));
        total += n;
      }
      if (total > _maxBatchBytes) throw const FormatException('batch exceeds 64 MiB');
    } on FormatException catch (e) {
      return _error(res, HttpStatus.badRequest, e.message);
    } on FileSystemException catch (e) {
      return _error(res, HttpStatus.badRequest, e.message);
    }

    final output = BytesBuilder(copy: false);
    for (final (file, start, n) in selected) {
      if (n == 0) continue;
      final raf = await file.open();
      try {
        await raf.setPosition(start);
        output.add(await raf.read(n));
      } finally {
        await raf.close();
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
    return _mimeOverrides[ext] ?? lookupMimeType(path) ?? 'application/octet-stream';
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
