// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

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
      final cmake = Platform.environment['TORRENT_ENGINE_CMAKE'] ?? 'cmake';
      Future<void> run(List<String> arguments) async {
        final result = await Process.run(cmake, arguments);
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
        if (os == OS.macOS)
          '-DCMAKE_OSX_ARCHITECTURES=${arch == Architecture.arm64 ? 'arm64' : 'x86_64'}',
        if (os == OS.macOS) '-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0',
        if (os == OS.windows) ...[
          '-A',
          arch == Architecture.arm64 ? 'ARM64' : 'x64',
        ],
        if (Platform.environment['OPENSSL_ROOT_DIR'] case final root?)
          '-DOPENSSL_ROOT_DIR=$root',
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
        native.resolve('CMakeLists.txt'),
        native.resolve('torrent_engine.cpp'),
        native.resolve('torrent_engine.h'),
        native.resolve('vendor/boost-1.85.0-headers.tar.gz'),
        native.resolve('vendor/libtorrent-2.0.15.tar.gz'),
      ]);
    } finally {
      await lock.unlock();
      await lock.close();
    }
  });
}
