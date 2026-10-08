// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'src/third_party/torrent_engine.g.dart' as native;

final class TorrentFile {
  const TorrentFile({
    required this.index,
    required this.path,
    required this.size,
  });
  final int index;
  final String path;
  final int size;
}

final class TorrentEngineException implements Exception {
  const TorrentEngineException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A bundled libtorrent session. All native calls and polling run in an isolate.
/// Files download only while a read requests their verified pieces.
final class TorrentEngine {
  TorrentEngine._(this._responses, this._onLog);
  final ReceivePort _responses;
  final void Function(String)? _onLog;
  final _ready = Completer<void>();
  final _port = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = {};
  late final StreamSubscription<dynamic> _subscription;
  int _nextId = 0;
  bool _disposed = false;
  bool _workerStopped = false;
  Future<void>? _disposing;

  /// Allocated disk bytes, including resume data, without following symlinks.
  static Future<int> cacheDiskUsage(String path) => Isolate.run(() {
    final value = path.toNativeUtf8();
    try {
      final bytes = native.te_disk_usage(value.cast());
      if (bytes < 0) {
        throw const TorrentEngineException(
          'Cannot measure torrent cache disk usage.',
        );
      }
      return bytes;
    } finally {
      calloc.free(value);
    }
  });

  /// Returns after the native session starts; metadata discovery remains async.
  static Future<TorrentEngine> open(
    String magnet,
    String cachePath, {
    void Function(String)? onLog,
  }) async {
    final engine = TorrentEngine._(ReceivePort(), onLog);
    engine._subscription = engine._responses.listen(engine._receive);
    // A very early worker failure can arrive before spawn completes.
    engine._ready.future.ignore();
    try {
      await Isolate.spawn(
        _worker,
        [engine._responses.sendPort, magnet, cachePath],
        onError: engine._responses.sendPort,
        onExit: engine._responses.sendPort,
      );
      await engine._ready.future;
      return engine;
    } catch (_) {
      await engine._subscription.cancel();
      engine._responses.close();
      rethrow;
    }
  }

  void _workerFailed(String message) {
    _workerStopped = true;
    final error = TorrentEngineException(message);
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }

  void _receive(dynamic value) {
    if (value == null) {
      if (!_workerStopped && (!_disposed || _pending.isNotEmpty)) {
        _workerFailed('Torrent worker exited unexpectedly.');
      }
      return;
    }
    final message = value as List;
    switch (message[0]) {
      case 'port':
        _port.complete(message[1] as SendPort);
      case 'opened':
        _ready.complete();
        _onLog?.call(
          'Bundled libtorrent session started; discovering metadata.',
        );
      case 'fatal':
        _workerFailed(message[1] as String);
      case 'reply':
        final pending = _pending.remove(message[1] as int);
        if (pending == null) return;
        if (message[2] as bool) {
          pending.complete(message[3]);
        } else {
          pending.completeError(TorrentEngineException(message[3] as String));
        }
      default:
        _workerFailed('Torrent worker failed: ${message.first}');
    }
  }

  (int, Future<Object?>) _call(
    String method, [
    List<Object?> values = const [],
  ]) {
    if ((_disposed || _workerStopped) && method != 'dispose') {
      throw const TorrentEngineException('Torrent engine has been disposed.');
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _port.future.then((port) => port.send([id, method, ...values]));
    return (id, completer.future);
  }

  Future<List<TorrentFile>> files() async {
    final rows = await _call('files').$2 as List;
    return rows
        .map(
          (dynamic row) => TorrentFile(
            index: row[0] as int,
            path: row[1] as String,
            size: row[2] as int,
          ),
        )
        .toList(growable: false);
  }

  /// The number of verified bytes retained in the sparse cache.
  Future<int> cachedBytes() async => await _call('cachedBytes').$2 as int;

  /// Reads [start, end), yielding chunks only after libtorrent verifies them.
  /// Canceling the subscription withdraws the outstanding piece request.
  Stream<List<int>> read(int fileIndex, int start, int end) {
    late final StreamController<List<int>> controller;
    var canceled = false;
    int? activeId;
    Completer<void>? resumed;
    Future<void> pump() async {
      try {
        final listing = await files();
        final matches = listing.where((file) => file.index == fileIndex);
        if (matches.isEmpty) {
          throw RangeError('Unknown torrent file $fileIndex');
        }
        final file = matches.single;
        if (start < 0 || end < start || end > file.size) {
          throw RangeError(
            'Invalid torrent range [$start, $end) for ${file.size} bytes',
          );
        }
        var position = start;
        while (!canceled && position < end) {
          if (controller.isPaused) {
            resumed ??= Completer<void>();
            await resumed!.future;
            if (canceled) break;
          }
          final call = _call('chunk', [fileIndex, position, end]);
          activeId = call.$1;
          final data = await call.$2 as TransferableTypedData;
          activeId = null;
          if (canceled) break;
          final bytes = data.materialize().asUint8List();
          position += bytes.length;
          controller.add(bytes);
        }
      } catch (error, stack) {
        if (!canceled) controller.addError(error, stack);
      } finally {
        if (!canceled) await controller.close();
      }
    }

    controller = StreamController<List<int>>(
      onListen: () {
        unawaited(pump());
      },
      onResume: () {
        resumed?.complete();
        resumed = null;
      },
      onCancel: () {
        canceled = true;
        resumed?.complete();
        resumed = null;
        if (activeId case final id?) {
          _port.future.then((port) => port.send([id, 'cancel']));
        }
      },
    );
    return controller.stream;
  }

  /// Pauses the torrent, saves metadata and verified piece state, stops peers,
  /// and releases the worker. Cached payload and resume data remain on disk.
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    try {
      if (!_workerStopped) await _call('dispose').$2;
    } finally {
      for (final pending in _pending.values) {
        pending.completeError(
          const TorrentEngineException('Torrent engine disposed.'),
        );
      }
      _pending.clear();
      await _subscription.cancel();
      _responses.close();
    }
  }
}

final class _Chunk {
  const _Chunk(this.id, this.piece, this.offset, this.length);
  final int id, piece, offset, length;
}

void _worker(List<Object?> arguments) {
  final replies = arguments[0] as SendPort;
  final commands = ReceivePort();
  replies.send(['port', commands.sendPort]);
  final magnet = (arguments[1] as String).toNativeUtf8();
  final cache = (arguments[2] as String).toNativeUtf8();
  Pointer<Void> engine;
  try {
    engine = native.te_open(magnet.cast(), cache.cast());
  } catch (error) {
    calloc.free(magnet);
    calloc.free(cache);
    replies.send(['fatal', 'Cannot load bundled torrent engine: $error']);
    commands.close();
    return;
  }
  calloc.free(magnet);
  calloc.free(cache);
  String nativeError() => native.te_error(engine).cast<Utf8>().toDartString();
  void reply(int id, Object? value) => replies.send(['reply', id, true, value]);
  void fail(int id, String error) => replies.send(['reply', id, false, error]);
  if (nativeError().isNotEmpty) {
    replies.send(['fatal', nativeError()]);
    native.te_close(engine);
    commands.close();
    return;
  }
  replies.send(['opened']);
  final metadataStarted = DateTime.now();
  var lastActivity = metadataStarted;
  var downloaded = 0;
  var ready = false;
  var stopped = false;
  String? failure;
  List<List<Object>> listing = [];
  final metadataWaiters = <int>{};
  final chunks = <int, _Chunk>{};
  final pieceWaiters = <int, Set<int>>{};
  void cancel(int id) {
    metadataWaiters.remove(id);
    final chunk = chunks.remove(id);
    if (chunk == null) return;
    final waiters = pieceWaiters[chunk.piece];
    if (waiters == null) return;
    waiters.remove(id);
    if (waiters.isEmpty) {
      pieceWaiters.remove(chunk.piece);
      native.te_release_piece(engine, chunk.piece);
    }
  }

  void activate() {
    for (final chunk in chunks.values) {
      var waiters = pieceWaiters[chunk.piece];
      if (waiters == null) {
        if (pieceWaiters.length >= 32) continue;
        native.te_request_piece(engine, chunk.piece);
        waiters = pieceWaiters[chunk.piece] = <int>{};
      }
      waiters.add(chunk.id);
    }
  }

  void abort(String error) {
    failure = error;
    for (final id in metadataWaiters) {
      fail(id, error);
    }
    metadataWaiters.clear();
    for (final id in chunks.keys.toList()) {
      cancel(id);
      fail(id, error);
    }
  }

  late final Timer timer;
  timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
    if (stopped || failure != null) return;
    try {
      final state = native.te_poll(engine);
      if (state < 0) {
        abort(nativeError());
        return;
      }
      if (!ready && state == 1) {
        ready = true;
        listing = [
          for (var i = 0; i < native.te_file_count(engine); i++)
            if (native
                .te_file_path(engine, i)
                .cast<Utf8>()
                .toDartString()
                .isNotEmpty)
              [
                i,
                native.te_file_path(engine, i).cast<Utf8>().toDartString(),
                native.te_file_size(engine, i),
              ],
        ];
        for (final id in metadataWaiters) {
          reply(id, listing);
        }
        metadataWaiters.clear();
      }
      final now = DateTime.now();
      if (!ready &&
          now.difference(metadataStarted) > const Duration(seconds: 60)) {
        abort('Torrent metadata discovery timed out after 60 seconds.');
        return;
      }
      final progress = native.te_downloaded(engine);
      if (progress > downloaded) {
        downloaded = progress;
        lastActivity = now;
      }
      for (final piece in pieceWaiters.keys.toList()) {
        final size = native.te_copy_piece(engine, piece, nullptr, 0);
        if (size < 0) {
          abort(nativeError());
          return;
        }
        if (size == 0) continue;
        final buffer = calloc<Uint8>(size);
        try {
          final count = native.te_copy_piece(engine, piece, buffer, size);
          if (count < 0) {
            abort(nativeError());
            return;
          }
          if (count == 0) continue;
          lastActivity = now;
          for (final id in pieceWaiters[piece]!.toList()) {
            final chunk = chunks.remove(id)!;
            final bytes = buffer
                .asTypedList(count)
                .sublist(chunk.offset, chunk.offset + chunk.length);
            reply(
              id,
              TransferableTypedData.fromList([Uint8List.fromList(bytes)]),
            );
          }
          pieceWaiters.remove(piece);
          native.te_release_piece(engine, piece);
        } finally {
          calloc.free(buffer);
        }
      }
      activate();
      if (chunks.isNotEmpty &&
          now.difference(lastActivity) > const Duration(seconds: 60)) {
        // A network stall fails current reads while allowing a later retry.
        for (final id in chunks.keys.toList()) {
          cancel(id);
          fail(id, 'Torrent network stalled: no progress for 60 seconds.');
        }
      }
    } catch (error) {
      abort('Torrent worker error: $error');
    }
  });
  commands.listen((dynamic value) {
    final message = value as List;
    final id = message[0] as int;
    final method = message[1] as String;
    try {
      if (method == 'dispose') {
        stopped = true;
        timer.cancel();
        abort('Torrent engine disposed.');
        native.te_close(engine);
        reply(id, null);
        commands.close();
        return;
      }
      if (method == 'cancel') {
        cancel(id);
        fail(id, 'Torrent read canceled.');
        return;
      }
      if (failure != null) {
        fail(id, failure!);
        return;
      }
      if (method == 'files') {
        if (ready) {
          reply(id, listing);
        } else {
          metadataWaiters.add(id);
        }
      } else if (method == 'cachedBytes') {
        reply(id, native.te_cached_bytes(engine));
      } else if (method == 'chunk') {
        if (!ready) throw StateError('Torrent metadata is not ready.');
        final file = message[2] as int;
        final start = message[3] as int;
        final end = message[4] as int;
        if (!listing.any((row) => row[0] == file) ||
            start < 0 ||
            end <= start ||
            end > native.te_file_size(engine, file)) {
          throw RangeError('Invalid torrent file or range.');
        }
        final length = native.te_piece_length(engine);
        final absolute = native.te_file_offset(engine, file) + start;
        final piece = absolute ~/ length;
        final offset = absolute % length;
        final available = native.te_piece_size(engine, piece) - offset;
        final count = [
          end - start,
          available,
          65536,
        ].reduce((a, b) => a < b ? a : b);
        if (chunks.isEmpty) lastActivity = DateTime.now();
        if (chunks.length >= 256) {
          throw StateError('Torrent engine read queue is full.');
        }
        chunks[id] = _Chunk(id, piece, offset, count);
        activate();
      } else {
        throw ArgumentError('Unknown torrent worker command $method');
      }
    } catch (error) {
      fail(id, error.toString());
    }
  });
}
