# Bundled torrent engine

`TorrentEngine.open(magnet, cachePath)` starts a libtorrent session in a worker
isolate. It returns before metadata discovery. `files()` waits for metadata;
`read(index, start, end)` streams verified bytes from the requested range and
cancels native demand when its subscription is canceled. Metadata discovery and
network inactivity time out after 60 seconds. `dispose()` pauses peers, saves
resume data and metadata, and stops the native session. Reopening the same
cache resumes retained verified pieces.

Payload is isolated under `cachePath/payload`; `resume.dat` occupies the cache
root. File priorities start at zero. Only demanded pieces receive deadlines,
with at most 32 active unique pieces and 256 pending chunks. Adjacent files may
share a demanded piece, so the cache can include verified bytes outside the
exact requested range. Libtorrent's sparse files/partfile retain these pieces.
Native metadata rejects symlinks and unsafe paths; pad files stay internal.
`cachedBytes()` reports libtorrent's retained done bytes; `cacheDiskUsage(path)`
recursively measures allocated bytes (`st_blocks` or `GetCompressedFileSizeW`)
without following symlinks.

## Build prerequisites

The Dart native asset hook builds and automatically bundles one self-contained
shared library on macOS, Windows and Linux. No installed torrent application is
used. Builds require CMake >=3.20, a C++17 toolchain, and **static OpenSSL**
development libraries. Missing OpenSSL fails the build; HTTPS trackers remain
supported. Flutter/Dart hooks read `openssl_root_windows` and `openssl_root_macos` from
`hooks.user_defines.torrent_engine` in the invoking package's pubspec. Paths
resolve relative to that pubspec; the repository stages dependencies under
`.dart_tool/native_dependencies/`. Use `cmake_executable` for a custom CMake
executable. Dart filters arbitrary environment variables, so `OPENSSL_ROOT_DIR`
and `TORRENT_ENGINE_CMAKE` alone are not hook configuration. Standalone CMake
accepts `-DOPENSSL_ROOT_DIR=...`.

- macOS: Xcode command line tools, CMake, OpenSSL (`brew openssl@3` includes
  static archives). For distribution, build OpenSSL for the app's minimum macOS
  version and each requested architecture; host Homebrew archives may require a
  newer macOS version than the launcher's deployment target.
- Linux: CMake, GCC/Clang, static libssl/libcrypto development archives (typically
  `libssl-dev`); use the build host matching your target architecture.
- Windows: Visual Studio C++ tools, CMake, Perl if needed by OpenSSL, static
  OpenSSL from vcpkg's `x64-windows-static`/`arm64-windows-static` triplet. Configure
  its installation through `openssl_root_windows`; the engine uses `/MT`.

The package .dart_tool/native_build directory retains CMake outputs across repeated
Flutter runs; a lock serializes concurrent builds. Sources are vendored and
SHA-256 checked, so building libtorrent and Boost requires no network. OpenSSL
is a host build dependency and is linked statically into the bundled library.

## Verification and generation

```sh
dart pub get
dart analyze
dart test
# Generate bindings in an isolated tool dependency graph:
dart run tool/ffigen.dart
# Native local-peer integration, including offline metadata/payload resume:
cmake -S native -B build/native -DTE_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/native --config Release --parallel
ctest --test-dir build/native --output-on-failure
# Enable the Dart worker's local-seeder test (macOS/Linux shell):
TORRENT_ENGINE_FIXTURE="$PWD/build/native/torrent_engine_integration" dart test
```

On Windows, set `TORRENT_ENGINE_FIXTURE` to the built
`torrent_engine_integration.exe` before running `dart test`.

The generator's separate pubspec lets FFIgen 23 coexist with Flutter's pinned
`meta` and older native asset dependency graph. Generated static FFI bindings
and recorded-use mappings live in `lib/src/third_party/`.

## Source provenance

- libtorrent 2.0.15: official release source archive,
  https://github.com/arvidn/libtorrent/releases/tag/v2.0.15, BSD-3-Clause.
- Boost 1.85.0 headers: derived from the official source archive with published
  SHA-256 `be0d91732d5b0cc6fbb275c7939974457e79b54d6f07ce2e3dfdd68bef883b0b`,
  https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.gz.
  The included archive retains `boost/` and `LICENSE_1_0.txt` only. File ownership
  and timestamps are normalized; the resulting archive's checksum is pinned in
  CMake. License: Boost Software License 1.0, included in the archive.

macOS is verified in this workspace. Windows/Linux require their respective
build hosts/toolchains; cross-platform configuration alone is not runtime
verification. This package runs no external torrent client process.

Set `TORRENT_ENGINE_DEBUG=1` to print native alerts and demanded piece state when
diagnosing tracker/peer issues. Include `THIRD_PARTY_NOTICES.md` with binary
distributions.
