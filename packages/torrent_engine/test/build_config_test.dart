import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:test/test.dart';
import 'package:torrent_engine/src/build_config.dart';

HookInputUserDefines defines(Uri workspace, Map<String, Object?> values) {
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: workspace.resolve('packages/torrent_engine/'),
      packageName: 'torrent_engine',
      outputDirectoryShared: workspace,
      outputFile: workspace.resolve('output.json'),
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: values,
          basePath: workspace,
        ),
      ),
    );
  return builder.build().userDefines;
}

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('torrent-build-config-');
  });
  tearDown(() async => temporary.delete(recursive: true));

  test('Windows forwards workspace OpenSSL and custom CMake without env', () {
    final config = NativeBuildConfig.fromUserDefines(
      defines(temporary.uri, {
        'openssl_root_windows': 'deps/windows-static',
        'openssl_root_macos': 'deps/macos',
        'cmake_executable': 'custom-cmake',
      }),
      targetOS: 'windows',
      architecture: 'x64',
    );
    expect(config.cmakeExecutable, 'custom-cmake');
    expect(
      config.configureArguments,
      containsAll([
        '-A',
        'x64',
        '-DOPENSSL_ROOT_DIR=${temporary.uri.resolve('deps/windows-static/').toFilePath()}',
      ]),
    );
  });

  test(
    'omitted OpenSSL allows discovery and macOS uses requested architecture',
    () {
      final config = NativeBuildConfig.fromUserDefines(
        defines(temporary.uri, {}),
        targetOS: 'macos',
        architecture: 'arm64',
      );
      expect(config.cmakeExecutable, 'cmake');
      expect(config.opensslRoot, isNull);
      expect(
        config.configureArguments,
        contains('-DCMAKE_OSX_ARCHITECTURES=arm64'),
      );
      expect(
        config.configureArguments,
        contains('-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0'),
      );
    },
  );

  test('explicit missing OpenSSL root fails before CMake runs', () async {
    final config = NativeBuildConfig.fromUserDefines(
      defines(temporary.uri, {'openssl_root_windows': 'missing'}),
      targetOS: 'windows',
      architecture: 'x64',
    );
    await expectLater(
      config.validate(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('openssl_root_windows'),
        ),
      ),
    );
  });

  test('configured directory resolves headers inside the root', () async {
    final header = File.fromUri(
      temporary.uri.resolve('deps/include/openssl/ssl.h'),
    );
    await header.parent.create(recursive: true);
    await header.writeAsString('fixture header');
    final config = NativeBuildConfig.fromUserDefines(
      defines(temporary.uri, {'openssl_root_macos': 'deps'}),
      targetOS: 'macos',
      architecture: 'arm64',
    );
    await config.validate();
    expect(config.opensslRoot!.resolve('include/openssl/ssl.h'), header.uri);
  });

  test(
    'changed root, executable or architecture discards stale CMake cache only',
    () async {
      NativeBuildConfig config(String root, String executable, String arch) =>
          NativeBuildConfig.fromUserDefines(
            defines(temporary.uri, {
              'openssl_root_windows': root,
              'cmake_executable': executable,
            }),
            targetOS: 'windows',
            architecture: arch,
          );
      final build = Directory.fromUri(temporary.uri.resolve('build/'));
      await build.create();
      var current = config('deps/a', 'cmake', 'x64');
      await current.invalidateCmakeCache(build.uri);
      for (final next in [
        config('deps/b', 'cmake', 'x64'),
        config('deps/b', 'other-cmake', 'x64'),
        config('deps/b', 'other-cmake', 'arm64'),
      ]) {
        final cache = File.fromUri(build.uri.resolve('CMakeCache.txt'));
        final generated = Directory.fromUri(build.uri.resolve('CMakeFiles/'));
        final dependency = File.fromUri(build.uri.resolve('_deps/keep.txt'));
        await cache.writeAsString('OPENSSL_ROOT_DIR:PATH=stale');
        await generated.create();
        await dependency.parent.create(recursive: true);
        await dependency.writeAsString('vendored source');
        await current.invalidateCmakeCache(build.uri);
        expect(await cache.exists(), isTrue);
        await next.invalidateCmakeCache(build.uri);
        expect(await cache.exists(), isFalse);
        expect(await generated.exists(), isFalse);
        expect(await dependency.readAsString(), 'vendored source');
        current = next;
      }
    },
  );
}
