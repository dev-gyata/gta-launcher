#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
native="$repo/packages/torrent_engine/.dart_tool/native_build/macos-arm64"
openssl="$repo/.dart_tool/native_dependencies/openssl-macos-arm64"
python3 "$repo/tool/release/verify_macos.py" --openssl "$openssl"
cmake -S "$repo/packages/torrent_engine/native" -B "$native" \
  -DTE_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DOPENSSL_ROOT_DIR="$openssl"
cmake --build "$native" --config Release --parallel "$(sysctl -n hw.ncpu)"
ctest --test-dir "$native" -C Release --output-on-failure
export TORRENT_ENGINE_FIXTURE="$native/torrent_engine_integration"
[[ -x "$TORRENT_ENGINE_FIXTURE" ]] || { echo 'Missing native fixture' >&2; exit 1; }
cd "$repo/packages/torrent_engine"
dart pub get
dart test
