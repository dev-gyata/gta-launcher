import 'dart:convert';
import 'dart:io';
import 'package:hooks/hooks.dart';

final class NativeBuildConfig {
  final String targetOS;
  final String architecture;
  final Uri? opensslRoot;
  final String cmakeExecutable;
  NativeBuildConfig(
    this.targetOS,
    this.architecture,
    this.opensslRoot,
    this.cmakeExecutable,
  );
  factory NativeBuildConfig.fromUserDefines(
    HookInputUserDefines defines, {
    required String targetOS,
    required String architecture,
  }) {
    final executable = defines['cmake_executable'];
    if (executable != null && (executable is! String || executable.isEmpty)) {
      throw const FormatException('cmake_executable must be a nonempty string');
    }
    final root = defines.path('openssl_root_$targetOS');
    final directory = root == null
        ? null
        : root.replace(
            path: root.path.endsWith('/') ? root.path : '${root.path}/',
          );
    return NativeBuildConfig(
      targetOS,
      architecture,
      directory,
      executable as String? ?? 'cmake',
    );
  }
  List<String> get configureArguments => [
    if (targetOS == 'macos') ...[
      '-DCMAKE_OSX_ARCHITECTURES=${architecture == 'arm64' ? 'arm64' : 'x86_64'}',
      '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0',
    ],
    if (targetOS == 'windows') ...[
      '-A',
      architecture == 'arm64' ? 'ARM64' : 'x64',
    ],
    if (opensslRoot != null) '-DOPENSSL_ROOT_DIR=${opensslRoot!.toFilePath()}',
  ];
  Future<void> validate() async {
    if (opensslRoot != null &&
        !await File.fromUri(
          opensslRoot!.resolve('include/openssl/ssl.h'),
        ).exists()) {
      throw StateError(
        'Missing static OpenSSL installation: openssl_root_$targetOS=${opensslRoot!.toFilePath()}. Prepare release dependencies first.',
      );
    }
  }

  Future<void> invalidateCmakeCache(Uri directory) async {
    final marker = File.fromUri(directory.resolve('configuration.json'));
    final value = jsonEncode([
      targetOS,
      architecture,
      opensslRoot?.toFilePath(),
      cmakeExecutable,
      '12.0',
      'MT',
    ]);
    if (!await marker.exists() || await marker.readAsString() != value) {
      final cache = File.fromUri(directory.resolve('CMakeCache.txt'));
      if (await cache.exists()) await cache.delete();
      final files = Directory.fromUri(directory.resolve('CMakeFiles/'));
      if (await files.exists()) await files.delete(recursive: true);
      await marker.writeAsString(value);
    }
  }
}
