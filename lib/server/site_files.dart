/// Site files shipped inside the launcher (`site/`), keyed by the URL path
/// they are served at. Everything else comes from the user's mirror folder.
library;

import 'dart:typed_data';

const buildPath = '/b/8b0b5899ed';

const siteFiles = {
  '/index.html': 'homepage.html',
  '$buildPath/loader.js': 'loader.js',
  '$buildPath/game.js': 'game.js',
  '$buildPath/io_worker.js': 'io_worker.js',
  '$buildPath/wgpu_worker.js': 'wgpu_worker.js',
  '/data/manifest.json': 'data-manifest.json',
  '$buildPath/shaders/index.json': 'shader-index.json',
};

/// Loads every entry of [siteFiles] with [read], which receives the file
/// name inside `site/` (asset bundle in the app, disk in tests/tools).
Future<Map<String, Uint8List>> loadSiteFiles(Future<Uint8List> Function(String name) read) async {
  return {for (final MapEntry(key: urlPath, value: name) in siteFiles.entries) urlPath: await read(name)};
}
