# playgta5 Launcher

[![Release](https://github.com/dev-gyata/gta-launcher/actions/workflows/release.yml/badge.svg)](https://github.com/dev-gyata/gta-launcher/actions/workflows/release.yml)

A desktop app for Windows, macOS and Linux that serves local folders, remote HTTP mirrors, and magnet-linked torrents through a localhost game server. It replaces running `serve_local.py` / `Launch-Local.cmd` by hand, and it doesn't need Python.

## Downloads

Grab the latest binaries from [GitHub Releases](https://github.com/dev-gyata/gta-launcher/releases/latest):

| OS | File | Contents |
| --- | --- | --- |
| Windows (x64) | `playgta5-launcher-windows-x64.zip` | Contents of `build/windows/x64/runner/Release/` — unzip and run `playgta5_launcher.exe` (needs the WebView2 Runtime, included with Windows 10/11) |
| macOS (arm64) | `playgta5-launcher-macos-arm64.zip` | `playgta5_launcher.app` — unzip and move it to Applications. The build is ad-hoc signed, so the first launch may need right-click → Open to pass Gatekeeper |
| Linux (x64) | `playgta5-launcher-linux-x64.tar.gz` | Contents of `build/linux/x64/release/bundle/` — extract and run `playgta5_launcher` |

Every `v*` tag (e.g. `v1.0.0`) builds all three OS binaries in CI and attaches them to that tag's release. Manual runs from the Actions tab publish a draft release instead.

The site's web files (`index.html`, `loader.js`, `game.js`, the workers and manifests) come with the launcher in `site/`. The game engine and its data don't. You need your own mirror folder containing `playgta5.com/b/8b0b5899ed/game.wasm` and `playgta5.com/data/`. Wherever a file exists in both places, the launcher's copy in `site/` is used.

## Usage
1. Choose a source:
   - **Local**: click **Choose…** and select `mirror`, `mirror/playgta5.com`, or their parent folder.
   - **HTTP**: paste a public folder URL such as `https://example.com/mirror/`. The launcher checks that URL and its `playgta5.com/` and `mirror/playgta5.com/` children. The host must expose file sizes through HEAD and support byte-range GET requests. Cloud sharing pages, authentication, and query-bearing URLs are not supported.
   - **Magnet**: paste a `magnet:?xt=…` link. Markdown-formatted links copied from chat are normalized without visiting the embedded websites; repeated tracker parameters are retained. A bundled libtorrent engine retrieves metadata and only the pieces covering requested game bytes.
2. Click **Start**. On macOS and Windows the game opens inside the launcher window. On Linux it opens in your browser. Use Chrome or Edge there because the game needs WebGPU. **Stop** also cancels metadata discovery, ZIP preparation, and mirror selection.

Torrents may contain an unpacked mirror or a ZIP archive with the same files. If several compatible mirror roots are found, the launcher asks you to choose one. ZIP64 is supported. Stored (uncompressed) ZIP entries stream directly; Deflate-compressed entries are downloaded and extracted individually before their first random read. The engine is checked/prepared before the game opens. Large compressed data files can still take time to prepare during play; the launcher log shows progress. Encrypted archives, split ZIPs, other compression methods, and unsafe paths are rejected.

Torrent pieces, resume state, and verified extracted entries persist in the application's support directory under `torrent-cache/`. The cache display reports allocated disk space, including sparse payloads, and **Clear torrent cache** removes it while stopped. There is no automatic eviction. Stopping closes peer connections and leaves cached data for the next launch. Browser data caches are isolated by source and mirror root.

The sample hash `57a4193cc3d3f069ce436fcda040ed4c705b76c7` and all seven supplied trackers are covered by the magnet-normalization test. Automated checks use generated fixture torrents and local seeders rather than relying on that torrent's live availability.

The game screen has buttons for **Launcher** (back), **Reload**, **Open in browser** and **Full screen**. You can switch the **Play in app** toggle off to always use the browser instead.

| OS | In-app engine | Notes |
| --- | --- | --- |
| macOS | WKWebView | Needs a macOS version whose WebKit has WebGPU (checked on macOS 27) |
| Windows | WebView2 | Needs the WebView2 Runtime (included with Windows 10/11). Without it, the app falls back to the browser |
| Linux | none | Always uses the browser |

If the webview can't run the game, a banner appears with an Open in browser button. The app remembers the source choice, separate values for each source, port, and play mode. Saved folder settings from earlier versions remain usable. If the port is busy, it uses a free one and shows the address.

## Build
Requires Flutter 3.44+, CMake 3.20+, a C++17 toolchain, and static OpenSSL development libraries for the target architecture. Build each OS on that OS. On macOS, install CMake and `openssl@3` with Homebrew; on Linux install CMake, the C++ compiler, and `libssl-dev` (or your distribution's equivalent). On Windows use Visual Studio C++ tools, CMake, and a static OpenSSL build. Set `OPENSSL_ROOT_DIR` when CMake cannot locate the static installation. For macOS distribution, build OpenSSL for the app's minimum macOS version; current Homebrew archives can target a newer OS.

`packages/torrent_engine` vendors checksum-verified libtorrent 2.0.15 and Boost 1.85.0 header archives. Its native build hook compiles a self-contained library and Flutter packages it with the app; users do not need a torrent client or OpenSSL installation. Incremental native build outputs are cached under the package's `.dart_tool/native_build/`. The first test/build takes longer because it compiles libtorrent.

Build each OS on that OS:
```
flutter pub get
flutter build windows   # build/windows/x64/runner/Release/
FLUTTER_XCODE_ARCHS=arm64 flutter build macos # build/macos/Build/Products/Release/playgta5_launcher.app
flutter build linux     # build/linux/x64/release/bundle/
```
On Linux you need the usual Flutter desktop packages: `clang cmake ninja-build pkg-config libgtk-3-dev`.
On an Intel Mac, use `FLUTTER_XCODE_ARCHS=x86_64` and matching OpenSSL archives. Build one architecture per invocation; the native engine hook packages the selected architecture.

### Releasing a new version

CI (`.github/workflows/release.yml`, Flutter stable) builds Windows, macOS (arm64) and Linux (x64) on their own runners and publishes the archives to [GitHub Releases](https://github.com/dev-gyata/gta-launcher/releases):

```
# 1. Bump `version:` in pubspec.yaml and commit
# 2. Tag and push — the tag name becomes the release name
git tag v1.0.0
git push origin v1.0.0
```

Pushing a `v*` tag creates (or updates) that tag's release with the three binaries and auto-generated notes. To test without tagging, run the workflow from the Actions tab: it accepts an optional `version` (e.g. `v1.0.0`) and otherwise publishes a `manual-build-<run>` draft release.

## Development
```
flutter analyze
flutter test                                  # server, sources, ZIP, settings, UI tests
node test/site/worker_cache_test.cjs            # browser worker cache isolation
dart run tool/serve.dart <mirror/playgta5.com> 8000   # run the server without the UI
```

| Path | Purpose |
| --- | --- |
| `lib/server/mirror_server.dart` | HTTP server: COOP/COEP/CORP headers, byte ranges, `POST /data/batch` |
| `lib/server/site_files.dart` | Maps each URL path to its file in `site/` |
| `site/` | The site's web files, bundled as Flutter assets |
| `lib/server/range.dart` | `Range` header parsing |
| `lib/services/mirror_validator.dart` | Finds the site root (needs `game.wasm` + `data/`) |
| `lib/sources/` | Local/HTTP/torrent adapters, magnet normalization, ZIP range index/extraction |
| `lib/services/source_manager.dart` | Source discovery, mirror selection, persistent torrent cache |
| `packages/torrent_engine/` | Bundled libtorrent C ABI, generated FFI, worker and native tests |
| `lib/services/settings.dart` | Saves source values, port and play mode |
| `lib/ui/launcher_page.dart` | The launcher screen |
| `lib/ui/game_page.dart` | In-app game view (embedded webview) |
| `lib/services/in_app_support.dart` | Detects whether in-app play works on this OS |

The macOS app sandbox is turned off so the app can still read the saved folder after a relaunch. Because of that, it can't be distributed through the Mac App Store.

The native engine has a generated fixture/local seeder test in `packages/torrent_engine/`; its README documents native integration checks and binding regeneration. Automated tests do not require the example torrent or public seeders. HTTP batch responses are assembled by the launcher, so an HTTP mirror does not need `/data/batch` support.
