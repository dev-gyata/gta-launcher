// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:torrent_engine/src/build_config.dart';

/// CMake owns the dependency graph for libtorrent's C++ build. The hook registers
/// its self-contained shared library so Flutter bundles it on every desktop OS.
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;
    if (os != OS.macOS && os != OS.linux && os != OS.windows) {
      throw UnsupportedError(
        'Torrent engine supports macOS, Windows, and Linux.',
      );
    }
    final native = input.packageRoot.resolve('native/');
    final directory = input.packageRoot.resolve(
      '.dart_tool/native_build/${os.name}-${arch.name}/',
    );
    await Directory.fromUri(directory).create(recursive: true);
    // Shared directory survives hook configuration changes; CMake rebuilds only
    // changed sources. File lock also protects concurrent Flutter test/builds.
    final lock = await File.fromUri(
      directory.resolve('build.lock'),
    ).open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    try {
      final config = NativeBuildConfig.fromUserDefines(
        input.userDefines,
        targetOS: os.name,
        architecture: arch.name,
      );
      await config.validate();
      await config.invalidateCmakeCache(directory);
      final cmake = config.cmakeExecutable;
      Future<void> run(List<String> arguments) async {
        final result = await Process.run(cmake, arguments);
        stdout.write(result.stdout);
        stderr.write(result.stderr);
        if (result.exitCode != 0) {
          throw StateError(
            'Torrent engine CMake build failed. Install CMake and a C++17 toolchain.\n${result.stdout}\n${result.stderr}',
          );
        }
      }

      await run([
        '-S',
        native.toFilePath(),
        '-B',
        directory.toFilePath(),
        '-DCMAKE_BUILD_TYPE=Release',
        ...config.configureArguments,
      ]);
      await run([
        '--build',
        directory.toFilePath(),
        '--config',
        'Release',
        '--target',
        'torrent_engine',
        '--parallel',
        '${Platform.numberOfProcessors.clamp(1, 8)}',
      ]);
      final filename = os.dylibFileName('torrent_engine');
      final binary = directory.resolve('lib/$filename');
      if (!await File.fromUri(binary).exists()) {
        throw StateError('Missing native engine: $binary');
      }
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'src/third_party/torrent_engine.g.dart',
          linkMode: DynamicLoadingBundled(),
          file: binary,
        ),
      );
      output.dependencies.addAll([
        input.packageRoot.resolve('lib/src/build_config.dart'),
        native.resolve('CMakeLists.txt'),
        native.resolve('torrent_engine.cpp'),
        native.resolve('torrent_engine.h'),
        native.resolve('torrent_path.h'),
        native.resolve('vendor/boost-1.85.0-headers.tar.gz'),
        native.resolve('vendor/libtorrent-2.0.15.tar.gz'),
      ]);
      final cache = await File.fromUri(
        directory.resolve('CMakeCache.txt'),
      ).readAsLines();
      for (final line in cache) {
        if (RegExp(
          r'^(OPENSSL_INCLUDE_DIR|OPENSSL_SSL_LIBRARY|OPENSSL_CRYPTO_LIBRARY|LIB_EAY_RELEASE|SSL_EAY_RELEASE):',
        ).hasMatch(line)) {
          final location = line.substring(line.indexOf('=') + 1);
          final entity = File(location);
          if (await entity.exists()) output.dependencies.add(entity.uri);
          if (line.startsWith('OPENSSL_INCLUDE_DIR:')) {
            final headers = Directory(location);
            if (await headers.exists()) {
              await for (final entry in headers.list(
                recursive: true,
                followLinks: false,
              )) {
                if (entry is File) output.dependencies.add(entry.uri);
              }
            }
          }
        }
      }
    } finally {
      await lock.unlock();
      await lock.close();
    }
  });
}
