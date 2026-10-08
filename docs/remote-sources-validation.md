# Remote source validation

Implemented local folders, HTTP folder discovery, normalized magnets, bundled
libtorrent, unpacked torrent mirrors, ZIP/ZIP64 range indexing and individual
Deflate entry preparation. Persistent torrent caches and browser cache namespaces
follow source identity. Stop cancels discovery, active reads and extraction.

Verified on the macOS development host:

- `flutter analyze`: no issues.
- `flutter test`: 90 tests passed, including existing local serving tests,
  HTTP discovery/transport, magnet normalization, ZIP safety/preparation,
  source cancellation, settings migration and launcher controls.
- `node test/site/worker_cache_test.cjs`: browser source cache isolation passed.
- Torrent engine `dart test`: four local-seeder integration tests passed.
- Native CTest: local piece-range, cancellation and offline resume fixture.
- macOS debug and arm64 release builds; both launched successfully.

The supplied magnet is a normalization fixture, not a network-dependent test.
Its live contents and playback have not been verified. Windows and Linux
build/runtime checks require their respective hosts. Build prerequisites and
macOS OpenSSL deployment-target requirements are documented in the READMEs.
