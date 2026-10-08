// Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
import 'dart:io';

/// The generator has its own dependency graph to remain compatible with
/// Flutter SDK packages that require older code_assets/meta versions.
Future<void> main() async {
  final directory = Platform.script.resolve('ffi_generator/').toFilePath();
  for (final arguments in [
    ['pub', 'get'],
    ['run', 'bin/generate.dart'],
  ]) {
    final process = await Process.start(
      Platform.resolvedExecutable,
      arguments,
      workingDirectory: directory,
      mode: ProcessStartMode.inheritStdio,
    );
    final status = await process.exitCode;
    if (status != 0) exit(status);
  }
}
