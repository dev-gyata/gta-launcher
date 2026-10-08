#!/usr/bin/env bash
# Build the same static OpenSSL on a developer Mac and the release runner.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'An arm64 macOS host is required.' >&2; exit 1;
}
version=3.6.4
prefix="$repo/.dart_tool/native_dependencies/openssl-macos-arm64"
work="$repo/.dart_tool/native_dependencies/openssl-source-$version"
mkdir -p "$work"
archive="openssl-$version.tar.gz"
url="https://github.com/openssl/openssl/releases/download/openssl-$version"
# Published at $url/$archive.sha256; pinned to keep subsequent builds identical.
checksum=9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef
cd "$work"
if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check --status; then
  curl --fail --location --retry 3 "$url/$archive" -o "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
rm -rf "openssl-$version"
tar -xzf "$archive"
cd "openssl-$version"
export MACOSX_DEPLOYMENT_TARGET=12.0
./Configure darwin64-arm64-cc no-shared no-module \
  -mmacosx-version-min=12.0 --prefix="$prefix" --libdir=lib
make -j "$(sysctl -n hw.ncpu)"
make install_sw
python3 "$repo/tool/release/verify_macos.py" --openssl "$prefix"
