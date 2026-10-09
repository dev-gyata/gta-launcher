<img src="docs/logo.png" alt="playgta5 Launcher logo" width="96">

# playgta5 Launcher

[![Release](https://github.com/dev-gyata/gta-launcher/actions/workflows/release.yml/badge.svg)](https://github.com/dev-gyata/gta-launcher/actions/workflows/release.yml)

A desktop app for Windows, macOS and Linux that serves local folders, remote HTTP mirrors, and magnet-linked torrents through a localhost game server. It replaces running `serve_local.py` / `Launch-Local.cmd` by hand, and it doesn't need Python.

> **Disclaimer:** This is an unofficial, independent project. It is not affiliated with, endorsed by, or sponsored by any game publisher or developer, and all trademarks belong to their respective owners. The launcher does not include the game engine, game data, or game artwork. You are responsible for only loading files you have the legal right to use.

## Screenshots

![macOS launcher showing Local, HTTP and Magnet source controls, torrent cache usage, and an invalid local folder warning](docs/screenshots/launcher.png)

Launcher on macOS. The selected local folder is invalid, so Start is disabled until a compatible mirror is chosen.

## Downloads

Grab the latest binaries from [GitHub Releases](https://github.com/dev-gyata/gta-launcher/releases/latest):

| OS | File | Contents |
| --- | --- | --- |
| Windows (x64) | `playgta5-launcher-windows-x64.zip` | Extract the whole folder and run `playgta5_launcher.exe` |
| macOS (arm64) | `playgta5-launcher-macos-arm64.zip` | Apple Silicon: unzip and move `playgta5_launcher.app` to Applications |
| Linux (x64) | `playgta5-launcher-linux-x64.tar.gz` | Contents of `build/linux/x64/release/bundle/` — extract and run `playgta5_launcher` |

Every `v*` tag (e.g. `v1.0.0`) builds all three OS binaries in CI and attaches them to that tag's release. Manual runs from the Actions tab build and upload artifacts without publishing by default; enable `publish` explicitly to publish a draft release.

The site's web files (`index.html`, `loader.js`, `game.js`, the workers and manifests) come with the launcher in `site/`. No game engine or game data is included or distributed with the launcher. To play, point it at a local folder, HTTP mirror, or torrent of files you are entitled to use, containing `playgta5.com/b/8b0b5899ed/game.wasm` and `playgta5.com/data/`. Wherever a file exists in both places, the launcher's copy in `site/` is used.

## Platform setup

Downloaded releases include the torrent engine. Users do not need Flutter, CMake, OpenSSL, Python, or a torrent client. Normal operation does not require administrator access. You need read access to local game files, writable application-support storage, and enough free space for persistent torrent and prepared ZIP caches. HTTP mirrors and magnets need internet access. Browser playback requires WebGPU support from both the browser and graphics hardware; use a current Chrome or Edge with hardware acceleration available.

### macOS

The downloadable macOS release targets Apple Silicon (arm64), with a macOS 12 minimum. Extract the ZIP and move the app to Applications. Current builds are ad-hoc signed, without Developer ID signing or Apple notarization, so Gatekeeper may block the first launch. If you trust the release, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** and confirm. See [Apple's instructions for opening downloaded apps](https://support.apple.com/en-hk/102445).

macOS may ask for access when you choose a mirror in a protected folder such as Documents, Desktop, or Downloads. Grant access to the folder you intend to use. The app sandbox is disabled, but normal filesystem permissions and macOS privacy controls still apply.

In-app playback uses WKWebView and requires WebGPU and cross-origin isolation. If the system webview cannot run the game, use **Open in browser** or turn off **Play in app**.

### Windows

Extract the entire ZIP before launching `playgta5_launcher.exe`; keep its DLLs and data folder alongside it. In-app playback needs the WebView2 Runtime. It is normally present on Windows 11 and many Windows 10 systems, but is not guaranteed on every installation. If missing, install the **Evergreen Runtime** from [Microsoft's official WebView2 download page](https://developer.microsoft.com/en-us/microsoft-edge/webview2/), or use browser playback. The launcher falls back to the browser if WebView2 is unavailable.

Windows may show a [SmartScreen warning for an unfamiliar release](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation). Torrent networking can also trigger a firewall prompt or be restricted by an existing firewall policy. If needed, allow this app on the trusted network you use; see [Microsoft's firewall guidance](https://support.microsoft.com/en-us/windows/security/windows-security/firewall-and-network-protection). Managed computers may require an administrator to change those policies.

### Linux

Extract the complete archive and keep the `bundle/` contents together, including `lib/` and `data/`. Run `playgta5_launcher` inside that folder. If extraction loses the executable permission, run `chmod +x playgta5_launcher` from the same folder.

The app needs GTK 3 runtime libraries, typically installed on desktop distributions. If missing, install your distribution's GTK 3 runtime package (for example, `libgtk-3-0` or `libgtk-3-0t64` on Debian/Ubuntu, depending on the release). Linux always opens the game in your browser; use Chrome or Edge on a system with WebGPU support.

macOS builds and startup have been checked locally. Windows and Linux build/runtime verification still require their respective hosts; the release workflow is configured to build them.

## Usage

1. Choose a source:
   - **Local**: click **Choose…** and select `mirror`, `mirror/playgta5.com`, or their parent folder.
   - **HTTP**: paste a public folder URL such as `https://example.com/mirror/`. The launcher checks that URL and its `playgta5.com/` and `mirror/playgta5.com/` children. The host must expose file sizes through HEAD and support byte-range GET requests. Cloud sharing pages, authentication, and query-bearing URLs are not supported.
   - **Magnet**: paste a `magnet:?xt=…` link. Markdown-formatted links copied from chat are normalized without visiting the embedded websites; repeated tracker parameters are retained. A bundled libtorrent engine retrieves metadata and only the pieces covering requested game bytes.
2. Click **Start**. On macOS and Windows the game opens inside the launcher window. On Linux it opens in your browser. Use Chrome or Edge there because the game needs WebGPU. **Stop** also cancels metadata discovery, ZIP preparation, and mirror selection.

Torrents may contain an unpacked mirror or a ZIP archive with the same files. If several compatible mirror roots are found, the launcher asks you to choose one. ZIP64 is supported. Stored (uncompressed) ZIP entries stream directly; Deflate-compressed entries are downloaded and extracted individually before their first random read. The engine is checked/prepared before the game opens. Large compressed data files can still take time to prepare during play; the launcher log shows progress. Encrypted archives, split ZIPs, other compression methods, and unsafe paths are rejected.

Torrent pieces, resume state, and verified extracted entries persist in the application's support directory under `torrent-cache/`. The cache display reports allocated disk space, including sparse payloads, and **Clear torrent cache** removes it while stopped. There is no automatic eviction. Stopping closes peer connections and leaves cached data for the next launch. Browser data caches are isolated by source and mirror root.

Automated checks use generated fixture torrents and local seeders, not public torrents.

The game screen has buttons for **Launcher** (back), **Reload**, **Open in browser** and **Full screen**. You can switch the **Play in app** toggle off to always use the browser instead.

If the webview can't run the game, a banner appears with an Open in browser button. The app remembers the source choice, separate values for each source, port, and play mode. Saved folder settings from earlier versions remain usable. If the port is busy, it uses a free one and shows the address.

### Controller

Xbox, PlayStation and other standard controllers work in the launcher window and in the browser. The game uses the controller as a real gamepad: analog sticks and triggers, the console button layout (D-pad down opens the character wheel, LB the weapon wheel), on-screen prompts that switch to controller buttons once you press one, and vibration. Keyboard and mouse keep working alongside it, and prompts switch back when you use them.

On the start screen, A picks Story Mode, X picks Sandbox Mode and B goes back. Vibration needs browser support: Chrome and Edge (including the Windows app) support it; the macOS app depends on the system WebKit version.

The launcher drives the game's own gamepad support through engine memory for build `8b0b5899ed`, without changing any game files. If that is unavailable it falls back to translating the controller into keyboard and mouse input (digital movement, keyboard prompts, no vibration). URL options: `?pad=keys` forces that fallback, `?padsens=1.5` sets its camera speed, and `?pad=0` turns the controller off.

## Build

Requires Flutter 3.44+, CMake 3.20+, a C++17 toolchain, and static OpenSSL development libraries for the target architecture. Build each OS on that OS. On macOS, install CMake and run `bash tool/release/build_openssl_macos.sh`; it builds checksum-verified static OpenSSL 3.6.4 for arm64 and macOS 12. On Linux install CMake, the C++ compiler, and `libssl-dev` (or your distribution's equivalent). On Windows use Visual Studio C++ tools and CMake, then run `vcpkg install openssl:x64-windows-static --x-install-root=.dart_tool/native_dependencies/vcpkg` from the repository root.

`packages/torrent_engine` vendors checksum-verified libtorrent 2.0.15 and Boost 1.85.0 header archives. Its native build hook compiles a self-contained library and Flutter packages it with the app; users do not need a torrent client or OpenSSL installation. Incremental native build outputs are cached under the package's `.dart_tool/native_build/`. The first test/build takes longer because it compiles libtorrent.

Build each OS on that OS:
```
flutter pub get
flutter build windows   # build/windows/x64/runner/Release/
FLUTTER_XCODE_ARCHS=arm64 flutter build macos # build/macos/Build/Products/Release/playgta5_launcher.app
flutter build linux     # build/linux/x64/release/bundle/
```
On Linux you need the usual Flutter desktop packages: `clang cmake ninja-build pkg-config libgtk-3-dev`.
The supplied macOS dependency script builds arm64. For an Intel source build, prepare x86_64 static OpenSSL targeting macOS 12, update `openssl_root_macos` below, and use `FLUTTER_XCODE_ARCHS=x86_64`. Build one architecture per invocation.

OpenSSL paths are configured under `hooks.user_defines.torrent_engine` in the root and native package pubspecs. `openssl_root_windows` and `openssl_root_macos` resolve relative to their pubspec; `cmake_executable` optionally selects a custom CMake executable. These user defines survive Dart's filtered build-hook environment. Setting `OPENSSL_ROOT_DIR` alone does not configure Flutter builds. Linux uses automatic system discovery; standalone CMake builds still accept `-DOPENSSL_ROOT_DIR=…`.

### Releasing a new version

CI (`.github/workflows/release.yml`, Flutter stable) builds Windows, macOS (arm64) and Linux (x64) on their own runners and publishes the archives to [GitHub Releases](https://github.com/dev-gyata/gta-launcher/releases):

```
# 1. Bump `version:` in pubspec.yaml and commit
# 2. Tag and push — the tag name becomes the release name
git tag v1.0.0
git push origin v1.0.0
```

Pushing a `v*` tag creates (or updates) that tag's release with the three binaries and auto-generated notes. To test without tagging, run the workflow from the Actions tab: leave `publish` disabled to verify all desktop builds without creating a release. Enable it only when you intend to publish a draft; `version` optionally selects its tag, otherwise the draft uses `manual-build-<run>`. Windows/macOS native integration and bundle compatibility checks run before packaging, and both extracted archives are checked. The Foundation plugin is constrained below 2.6 to avoid Flutter's macOS 13 native-asset minimum.

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

The current macOS build cannot be distributed through the Mac App Store because its sandbox is disabled. Public distribution with fewer Gatekeeper prompts requires Developer ID signing and notarization; the current release workflow does not perform those steps.

The native engine has a generated fixture/local seeder test in `packages/torrent_engine/`; its README documents native integration checks and binding regeneration. Automated tests do not require the example torrent or public seeders. HTTP batch responses are assembled by the launcher, so an HTTP mirror does not need `/data/batch` support.

CI caches the Flutter SDK and pub packages through `flutter-action`, static OpenSSL installations, native libtorrent/engine compilation, and CocoaPods downloads. Native cache keys include the runner OS, architecture, image/toolchain version, and dependency configuration; source changes restore compatible objects and let CMake rebuild changed files. OpenSSL caches use exact configuration keys and are saved before application verification. Tests, bundle checks, and packaging still run on every build. The first run for a new configuration fills the caches; later runs reuse them. Final app bundles and extracted verification directories are rebuilt rather than cached.
