import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'mirror_source.dart';

/// Indexes a ZIP using bounded range reads. Payloads are fetched only on demand.
/// Stored members remain range-readable; deflated members are verified before
/// their persistent cache files become visible to readers.
class ZipMirrorSource {
  ZipMirrorSource._(
    this._source,
    this._archivePath,
    this._cache,
    this._cancellation,
    this._onLog,
    this._archiveSize,
  );

  final MirrorSource _source;
  final String _archivePath;
  final Directory _cache;
  final SourceCancellation _cancellation;
  final void Function(String)? _onLog;
  final int _archiveSize;
  final Map<String, _Entry> _entries = {};
  final Set<String> _directories = {''};
  final Map<String, Future<File>> _preparations = {};
  final Set<Future<int>> _headers = {};
  final List<Completer<void>> _slotWaiters = [];
  int _activePreparations = 0;
  late final int _directoryOffset;
  List<String> _roots = [];
  Future<void>? _disposal;
  Future<Directory>? _cacheRoot;

  static Future<ZipMirrorSource> open(
    MirrorSource source,
    String path,
    Directory cache, {
    SourceCancellation? cancellation,
    void Function(String)? onLog,
  }) async {
    final token = cancellation ?? SourceCancellation();
    token.check();
    if (!safeSourcePath(path)) {
      throw const SourceException('Unsafe archive path');
    }
    final info = await token.bind(source.stat(path));
    if (info == null || info.isDirectory || info.size < 22) {
      throw const SourceException('Archive is missing or is not a ZIP file');
    }
    final zip = ZipMirrorSource._(source, path, cache, token, onLog, info.size);
    try {
      await zip._index();
      token.check();
      return zip;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException('Invalid ZIP archive: $error');
    }
  }

  List<String> get mirrorRoots => List.unmodifiable(_roots);

  MirrorSource forRoot(String prefix) {
    _cancellation.check();
    if (!safeSourcePath(prefix)) {
      throw const SourceException('Unsafe archive root');
    }
    if (prefix.endsWith('/')) prefix = prefix.substring(0, prefix.length - 1);
    if (!_safeEntryName(prefix, allowEmpty: true)) {
      throw const SourceException('Unsafe archive root');
    }
    if (!_directories.contains(prefix)) {
      throw const SourceException('Archive directory not found', status: 404);
    }
    return _ZipRoot(this, prefix);
  }

  String get _identity => 'zip:${_source.identity}:$_archivePath';

  Future<void> _index() async {
    _onLog?.call('Reading ZIP directory: $_archivePath');
    final tailStart = math.max(0, _archiveSize - 65557);
    final tail = await _bytes(tailStart, _archiveSize);
    final view = ByteData.sublistView(tail);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(view, i) == 0x06054b50 &&
          i + 22 + _u16(view, i + 20) == tail.length) {
        end = i;
        break;
      }
    }
    if (end < 0) throw const SourceException('ZIP end record not found');
    if (_u16(view, end + 4) != 0 || _u16(view, end + 6) != 0) {
      throw const SourceException('Split ZIP archives are unsupported');
    }
    var count = _u16(view, end + 10);
    var directorySize = _u32(view, end + 12);
    var directoryOffset = _u32(view, end + 16);
    var directoryLimit = tailStart + end;
    if (count == 0xffff ||
        _u16(view, end + 8) == 0xffff ||
        directorySize == 0xffffffff ||
        directoryOffset == 0xffffffff) {
      if (directoryLimit < 20) {
        throw const SourceException('Missing ZIP64 locator');
      }
      final locator = ByteData.sublistView(
        await _bytes(directoryLimit - 20, directoryLimit),
      );
      if (_u32(locator, 0) != 0x07064b50 ||
          _u32(locator, 4) != 0 ||
          _u32(locator, 16) != 1) {
        throw const SourceException('Invalid or split ZIP64 archive');
      }
      final recordOffset = _u64(locator, 8);
      if (!_fits(recordOffset, 56, directoryLimit - 20)) {
        throw const SourceException('ZIP64 directory record is out of bounds');
      }
      final record = ByteData.sublistView(
        await _bytes(recordOffset, recordOffset + 56),
      );
      final recordSize = _u64(record, 4);
      if (_u32(record, 0) != 0x06064b50 ||
          recordSize < 44 ||
          !_fits(recordOffset + 12, recordSize, directoryLimit - 20) ||
          _u32(record, 16) != 0 ||
          _u32(record, 20) != 0 ||
          _u64(record, 24) != _u64(record, 32)) {
        throw const SourceException('Invalid ZIP64 directory record');
      }
      count = _u64(record, 32);
      directorySize = _u64(record, 40);
      directoryOffset = _u64(record, 48);
      directoryLimit = recordOffset;
    } else if (_u16(view, end + 8) != count) {
      throw const SourceException('Split ZIP archives are unsupported');
    }
    if (count > 100000 ||
        directorySize > 64 * 1024 * 1024 ||
        !_fits(directoryOffset, directorySize, directoryLimit)) {
      throw const SourceException('ZIP directory exceeds supported bounds');
    }
    _directoryOffset = directoryOffset;
    final directory = await _bytes(
      directoryOffset,
      directoryOffset + directorySize,
    );
    final data = ByteData.sublistView(directory);
    final populatedDirectories = <String>{};
    var cursor = 0;
    for (var index = 0; index < count; index++) {
      _cancellation.check();
      if (!_fits(cursor, 46, directory.length) ||
          _u32(data, cursor) != 0x02014b50) {
        throw const SourceException('Malformed ZIP central directory');
      }
      final flags = _u16(data, cursor + 8);
      final method = _u16(data, cursor + 10);
      final nameSize = _u16(data, cursor + 28);
      final extraSize = _u16(data, cursor + 30);
      final recordSize = 46 + nameSize + extraSize + _u16(data, cursor + 32);
      if (!_fits(cursor, recordSize, directory.length)) {
        throw const SourceException('Truncated ZIP directory entry');
      }
      if ((flags & 0x2041) != 0) {
        throw const SourceException('Encrypted ZIP entries are unsupported');
      }
      if (method != 0 && method != 8) {
        throw SourceException('Unsupported ZIP compression method: $method');
      }
      final rawName = Uint8List.sublistView(
        directory,
        cursor + 46,
        cursor + 46 + nameSize,
      );
      final fullName = _decodeName(rawName, flags);
      final isDirectory = fullName.endsWith('/');
      final name = isDirectory
          ? fullName.substring(0, fullName.length - 1)
          : fullName;
      if (!_safeEntryName(name)) {
        throw SourceException('Unsafe ZIP entry: $fullName');
      }
      final mode = _u32(data, cursor + 38) >> 16;
      if ((mode & 0xf000) == 0xa000) {
        throw SourceException('ZIP symlinks are unsupported: $name');
      }
      var size = _u32(data, cursor + 24);
      var compressedSize = _u32(data, cursor + 20);
      var offset = _u32(data, cursor + 42);
      var disk = _u16(data, cursor + 34);
      final extra = Uint8List.sublistView(
        directory,
        cursor + 46 + nameSize,
        cursor + 46 + nameSize + extraSize,
      );
      final values = _zip64Values(extra, [
        size == 0xffffffff,
        compressedSize == 0xffffffff,
        offset == 0xffffffff,
        disk == 0xffff,
      ]);
      var vi = 0;
      if (size == 0xffffffff) size = values[vi++];
      if (compressedSize == 0xffffffff) compressedSize = values[vi++];
      if (offset == 0xffffffff) offset = values[vi++];
      if (disk == 0xffff) disk = values[vi++];
      if (disk != 0) {
        throw const SourceException('Split ZIP archives are unsupported');
      }
      if (!_fits(offset, 30, directoryOffset) ||
          (method == 0 && size != compressedSize) ||
          (isDirectory && size != 0)) {
        throw SourceException('Invalid ZIP entry bounds: $name');
      }
      if (_entries.containsKey(name)) {
        throw SourceException('Duplicate ZIP entry: $name');
      }
      _entries[name] = _Entry(
        name,
        rawName,
        flags,
        method,
        size,
        compressedSize,
        _u32(data, cursor + 16),
        offset,
        isDirectory,
        _dosDate(_u16(data, cursor + 14), _u16(data, cursor + 12)),
      );
      if (isDirectory) _directories.add(name);
      var parent = name.lastIndexOf('/');
      while (parent >= 0) {
        final directory = name.substring(0, parent);
        _directories.add(directory);
        if (!isDirectory) populatedDirectories.add(directory);
        parent = name.lastIndexOf('/', parent - 1);
      }
      cursor += recordSize;
    }
    if (cursor != directory.length) {
      // An optional central-directory digital signature may follow the entries.
      if (!_fits(cursor, 6, directory.length) ||
          _u32(data, cursor) != 0x05054b50 ||
          cursor + 6 + _u16(data, cursor + 4) != directory.length) {
        throw const SourceException('Unexpected ZIP directory data');
      }
    }
    for (final entry in _entries.values) {
      if (!entry.directory && _directories.contains(entry.name)) {
        throw SourceException(
          'ZIP file conflicts with a directory: ${entry.name}',
        );
      }
    }
    const wasm = 'b/8b0b5899ed/game.wasm';
    final roots = <String>[];
    for (final entry in _entries.values) {
      if (entry.directory) continue;
      final prefix = entry.name == wasm
          ? ''
          : entry.name.endsWith('/$wasm')
          ? entry.name.substring(0, entry.name.length - wasm.length - 1)
          : null;
      if (prefix == null) continue;
      final dataDirectory = prefix.isEmpty ? 'data' : '$prefix/data';
      if (populatedDirectories.contains(dataDirectory)) {
        roots.add(prefix);
      }
    }
    roots.sort();
    _roots = roots;
    _onLog?.call(
      'ZIP indexed: ${_entries.length} entries, ${roots.length} mirror roots',
    );
  }

  Future<SourceFile?> _stat(String path) async {
    _cancellation.check();
    final entry = _entries[path];
    if (entry != null) {
      return SourceFile(
        entry.size,
        isDirectory: entry.directory,
        modified: entry.modified,
      );
    }
    return _directories.contains(path)
        ? const SourceFile(0, isDirectory: true)
        : null;
  }

  Stream<List<int>> _read(String path, int start, int end) async* {
    _cancellation.check();
    final entry = _entries[path];
    if (entry == null || entry.directory) {
      throw const SourceException('File not found', status: 404);
    }
    if (start < 0 || end < start || end > entry.size) {
      throw const SourceException('Invalid ZIP member range', status: 416);
    }
    if (entry.method == 0) {
      final offset = await _offset(entry);
      if (start == end) return;
      yield* _chunks(offset + start, offset + end);
    } else {
      final file = await _cancellation.bind(
        _preparations.putIfAbsent(entry.name, () {
          final future = _prepare(entry);
          future.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {
              if (identical(_preparations[entry.name], future)) {
                _preparations.remove(entry.name);
              }
            },
          );
          return future;
        }),
      );
      await _checkCachePath(await _cacheDirectory(), file.path);
      if (start == end) return;
      yield* _cancelable(file.openRead(start, end));
    }
  }

  Future<int> _offset(_Entry entry) {
    return entry.dataOffset ??= (() {
      final future = _validateHeader(entry);
      _headers.add(future);
      // Keep failures observed while still propagating them to the requester.
      future.then<void>(
        (_) {
          _headers.remove(future);
        },
        onError: (Object _, StackTrace _) {
          _headers.remove(future);
          if (identical(entry.dataOffset, future)) entry.dataOffset = null;
        },
      );
      return future;
    })();
  }

  Future<int> _validateHeader(_Entry entry) async {
    final local = ByteData.sublistView(
      await _bytes(entry.offset, entry.offset + 30),
    );
    if (_u32(local, 0) != 0x04034b50 ||
        _u16(local, 6) != entry.flags ||
        _u16(local, 8) != entry.method) {
      throw SourceException('ZIP local header mismatch: ${entry.name}');
    }
    final nameSize = _u16(local, 26);
    final extraSize = _u16(local, 28);
    final dataOffset = entry.offset + 30 + nameSize + extraSize;
    if (!_fits(dataOffset, entry.compressedSize, _directoryOffset)) {
      throw SourceException('ZIP member data is out of bounds: ${entry.name}');
    }
    final variable = await _bytes(entry.offset + 30, dataOffset);
    if (nameSize != entry.rawName.length ||
        !List.generate(
          nameSize,
          (i) => variable[i] == entry.rawName[i],
        ).every((v) => v)) {
      throw SourceException('ZIP local filename mismatch: ${entry.name}');
    }
    if ((entry.flags & 8) == 0) {
      var size = _u32(local, 22);
      var compressedSize = _u32(local, 18);
      final values = _zip64Values(Uint8List.sublistView(variable, nameSize), [
        size == 0xffffffff,
        compressedSize == 0xffffffff,
      ]);
      var i = 0;
      if (size == 0xffffffff) size = values[i++];
      if (compressedSize == 0xffffffff) compressedSize = values[i++];
      if (size != entry.size ||
          compressedSize != entry.compressedSize ||
          _u32(local, 14) != entry.crc) {
        throw SourceException('ZIP local sizes or CRC mismatch: ${entry.name}');
      }
    }
    return dataOffset;
  }

  Future<File> _prepare(_Entry entry) async {
    final cache = await _cacheDirectory();
    final base = '${entry.offset}-${entry.crc}-${entry.size}';
    final file = File(p.join(cache.path, '$base.bin'));
    final marker = File(p.join(cache.path, '$base.complete'));
    await _checkCachePath(cache, file.path);
    await _checkCachePath(cache, marker.path);
    final identity = jsonEncode([
      _identity,
      _archiveSize,
      entry.name,
      entry.offset,
      entry.size,
      entry.compressedSize,
      entry.crc,
      entry.method,
      entry.flags,
    ]);
    _cancellation.check();
    try {
      if (await marker.exists() &&
          await marker.readAsString() == identity &&
          await file.exists() &&
          await file.length() == entry.size) {
        _cancellation.check();
        return file;
      }
    } on FileSystemException {
      // A missing or interrupted completion marker requires fresh verification.
    }
    await _acquireSlot();
    Directory? temporary;
    RandomAccessFile? output;
    try {
      _cancellation.check();
      final offset = await _offset(entry);
      await _checkCachePath(cache, cache.path, directory: true);
      temporary = await cache.createTemp('preparing-');
      await _checkCachePath(cache, temporary.path, directory: true);
      final partial = File(p.join(temporary.path, 'member'));
      await _checkCachePath(cache, partial.path);
      output = await partial.open(mode: FileMode.write);
      await _checkCachePath(cache, partial.path);
      _onLog?.call(
        'Preparing compressed ZIP entry: ${entry.name} (${entry.size} bytes)',
      );
      var size = 0;
      var crc = 0xffffffff;
      var lastProgress = DateTime.now();
      final decoded = _chunks(
        offset,
        offset + entry.compressedSize,
      ).transform(ZLibDecoder(raw: true));
      await for (final bytes in _cancelable(decoded)) {
        _cancellation.check();
        size += bytes.length;
        if (size > entry.size) {
          throw SourceException(
            'ZIP inflated size exceeds metadata: ${entry.name}',
          );
        }
        crc = _updateCrc(crc, bytes);
        await output.writeFrom(bytes);
        final now = DateTime.now();
        if (now.difference(lastProgress).inSeconds >= 1) {
          _onLog?.call('Preparing ${entry.name}: $size / ${entry.size} bytes');
          lastProgress = now;
        }
      }
      if (size != entry.size || (crc ^ 0xffffffff) != entry.crc) {
        throw SourceException('ZIP size or CRC check failed: ${entry.name}');
      }
      _cancellation.check();
      await output.flush();
      await output.close();
      output = null;
      await _checkCachePath(cache, partial.path);
      await _checkCachePath(cache, file.path);
      await partial.rename(file.path);
      _cancellation.check();
      final completion = File(p.join(temporary.path, 'completion'));
      await _checkCachePath(cache, completion.path);
      await completion.writeAsString(identity, flush: true);
      _cancellation.check();
      await _checkCachePath(cache, completion.path);
      await _checkCachePath(cache, marker.path);
      await completion.rename(marker.path);
      _onLog?.call('ZIP entry ready: ${entry.name}');
      return file;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException('Cannot prepare ZIP entry ${entry.name}: $error');
    } finally {
      try {
        if (output != null) await output.close();
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await _checkCachePath(cache, temporary.path, directory: true);
            await temporary.delete(recursive: true);
          }
        } finally {
          _releaseSlot();
        }
      }
    }
  }

  Future<Directory> _cacheDirectory() =>
      _cacheRoot ??= _validateCacheDirectory();

  Future<Directory> _validateCacheDirectory() async {
    _cancellation.check();
    final requested = Directory(p.normalize(p.absolute(_cache.path)));
    await _createCacheDirectory(requested);
    final parent = await requested.parent.resolveSymbolicLinks();
    final canonical = await requested.resolveSymbolicLinks();
    if (!p.equals(canonical, p.join(parent, p.basename(requested.path)))) {
      throw const SourceException('ZIP cache directory escapes its parent');
    }
    final root = Directory(canonical);
    // The application owns the supplied cache's parent. System aliases such
    // as /var may precede it; all members beneath this canonical root must be
    // ordinary files or directories, including abandoned preparation files.
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      _cancellation.check();
      if (entity is Link ||
          await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.link) {
        throw const SourceException('ZIP cache contains a symbolic link');
      }
    }
    await _checkCachePath(root, root.path, directory: true);
    return root;
  }

  Future<void> _createCacheDirectory(Directory directory) async {
    _cancellation.check();
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw const SourceException('ZIP cache directory is a symbolic link');
    }
    if (type == FileSystemEntityType.directory) return;
    if (type != FileSystemEntityType.notFound ||
        p.equals(directory.path, directory.parent.path)) {
      throw const SourceException('Invalid ZIP cache directory');
    }
    await _createCacheDirectory(directory.parent);
    await directory.create();
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const SourceException(
        'ZIP cache directory changed during creation',
      );
    }
  }

  Future<void> _checkCachePath(
    Directory root,
    String path, {
    bool directory = false,
  }) async {
    if (!p.equals(path, root.path) && !p.isWithin(root.path, path)) {
      throw const SourceException('ZIP cache destination is outside its root');
    }
    final canonical = await root.resolveSymbolicLinks();
    if (!p.equals(canonical, root.path)) {
      throw const SourceException('ZIP cache directory was redirected');
    }
    final relative = p.relative(path, from: root.path);
    final paths = <String>[root.path];
    if (relative != '.') {
      var current = root.path;
      for (final component in p.split(relative)) {
        current = p.join(current, component);
        paths.add(current);
      }
    }
    for (var i = 0; i < paths.length; i++) {
      final last = i == paths.length - 1;
      final type = await FileSystemEntity.type(paths[i], followLinks: false);
      final expected = !last || directory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file;
      if (type != expected &&
          !(last && !directory && type == FileSystemEntityType.notFound)) {
        throw const SourceException(
          'ZIP cache destination is not a regular file or directory',
        );
      }
      if (type != FileSystemEntityType.notFound) {
        final real = await File(paths[i]).resolveSymbolicLinks();
        if (!p.equals(real, paths[i])) {
          throw const SourceException('ZIP cache destination was redirected');
        }
      }
    }
  }

  Future<void> _acquireSlot() async {
    while (_activePreparations >= 2) {
      final waiter = Completer<void>();
      _slotWaiters.add(waiter);
      try {
        await _cancellation.bind(waiter.future);
      } finally {
        _slotWaiters.remove(waiter);
      }
    }
    _cancellation.check();
    _activePreparations++;
  }

  void _releaseSlot() {
    _activePreparations--;
    if (_slotWaiters.isNotEmpty) {
      final next = _slotWaiters.removeAt(0);
      if (!next.isCompleted) next.complete();
    }
  }

  Stream<List<int>> _cancelable(Stream<List<int>> source) async* {
    _cancellation.check();
    final iterator = StreamIterator(source);
    try {
      while (await _cancellation.bind(iterator.moveNext())) {
        _cancellation.check();
        yield iterator.current;
      }
    } finally {
      // Some underlying range sources are blocked waiting for a torrent piece.
      // Do not wait for their subscription cancellation to finish our cleanup.
      unawaited(iterator.cancel().catchError((Object _) {}));
    }
  }

  Stream<List<int>> _chunks(int start, int end) async* {
    if (!_fits(start, end - start, _archiveSize)) {
      throw const SourceException('ZIP range is out of bounds');
    }
    var received = 0;
    await for (final bytes in _cancelable(
      _source.read(_archivePath, start, end),
    )) {
      received += bytes.length;
      if (received > end - start) {
        throw const SourceException('Archive source exceeded requested range');
      }
      yield bytes;
    }
    if (received != end - start) {
      throw const SourceException('Archive source returned a truncated range');
    }
  }

  Future<Uint8List> _bytes(int start, int end) async {
    final result = BytesBuilder(copy: false);
    await for (final bytes in _chunks(start, end)) {
      result.add(bytes);
    }
    return result.takeBytes();
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _cancellation.cancel();
    await Future.wait([
      ..._preparations.values.map(
        (f) => f.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
      ..._headers.map(
        (f) => f.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    ]);
    await _source.dispose();
  }
}

class _ZipRoot implements MirrorSource {
  _ZipRoot(this.zip, this.prefix);
  final ZipMirrorSource zip;
  final String prefix;
  String? _path(String path) => _safeEntryName(path, allowEmpty: true)
      ? prefix.isEmpty
            ? path
            : path.isEmpty
            ? prefix
            : '$prefix/$path'
      : null;
  @override
  String get identity => '${zip._identity}:$prefix';
  @override
  Future<SourceFile?> stat(String path) async {
    zip._cancellation.check();
    final name = _path(path);
    return name == null ? null : zip._stat(name);
  }

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    final name = _path(path);
    if (name == null) {
      throw const SourceException('File not found', status: 404);
    }
    yield* zip._read(name, start, end);
  }

  @override
  Future<void> dispose() => zip.dispose();
}

class _Entry {
  _Entry(
    this.name,
    this.rawName,
    this.flags,
    this.method,
    this.size,
    this.compressedSize,
    this.crc,
    this.offset,
    this.directory,
    this.modified,
  );
  final String name;
  final Uint8List rawName;
  final int flags, method, size, compressedSize, crc, offset;
  final bool directory;
  final DateTime? modified;
  Future<int>? dataOffset;
}

bool _safeEntryName(String path, {bool allowEmpty = false}) =>
    (path.isEmpty
        ? allowEmpty
        : path
              .split('/')
              .every((part) => part.isNotEmpty && !part.contains(':'))) &&
    safeSourcePath(path);

bool _fits(int offset, int size, int limit) =>
    offset >= 0 && size >= 0 && offset <= limit && size <= limit - offset;
int _u16(ByteData data, int offset) => data.getUint16(offset, Endian.little);
int _u32(ByteData data, int offset) => data.getUint32(offset, Endian.little);
int _u64(ByteData data, int offset) {
  final value = data.getUint64(offset, Endian.little);
  if (value < 0) {
    throw const SourceException('ZIP64 value exceeds supported bounds');
  }
  return value;
}

List<int> _zip64Values(Uint8List extra, List<bool> wanted) {
  final data = ByteData.sublistView(extra);
  var cursor = 0;
  List<int>? values;
  while (cursor < extra.length) {
    if (!_fits(cursor, 4, extra.length)) {
      throw const SourceException('Malformed ZIP extra field');
    }
    final kind = _u16(data, cursor);
    final size = _u16(data, cursor + 2);
    cursor += 4;
    if (!_fits(cursor, size, extra.length)) {
      throw const SourceException('Truncated ZIP extra field');
    }
    if (kind == 1) {
      if (values != null) {
        throw const SourceException('Duplicate ZIP64 extra field');
      }
      values = [];
      var next = cursor;
      for (var index = 0; index < wanted.length; index++) {
        if (!wanted[index]) continue;
        final width = index == 3 ? 4 : 8;
        if (!_fits(next, width, cursor + size)) {
          throw const SourceException('Missing ZIP64 entry value');
        }
        values.add(width == 4 ? _u32(data, next) : _u64(data, next));
        next += width;
      }
    }
    cursor += size;
  }
  if (values == null && wanted.any((v) => v)) {
    throw const SourceException('Missing ZIP64 extra field');
  }
  return values ?? [];
}

String _decodeName(List<int> bytes, int flags) {
  if ((flags & 0x800) != 0) return utf8.decode(bytes);
  // ZIP's legacy default is IBM code page 437, not the host's locale.
  const high =
      'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';
  return String.fromCharCodes(
    bytes.map((b) => b < 128 ? b : high.codeUnitAt(b - 128)),
  );
}

DateTime? _dosDate(int date, int time) {
  if (date == 0) return null;
  return DateTime(
    1980 + (date >> 9),
    (date >> 5) & 15,
    date & 31,
    time >> 11,
    (time >> 5) & 63,
    (time & 31) * 2,
  );
}

final _crcTable = List<int>.generate(256, (value) {
  var crc = value;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
  }
  return crc;
});

int _updateCrc(int crc, List<int> bytes) {
  for (final byte in bytes) {
    crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 255];
  }
  return crc;
}
