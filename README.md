# playgta5 Launcher

A desktop app for Windows, macOS and Linux that serves a local playgta5 mirror folder and opens it in your browser. It replaces running `serve_local.py` / `Launch-Local.cmd` by hand, and it doesn't need Python.

The site's web files (`index.html`, `loader.js`, `game.js`, the workers and manifests) come with the launcher in `site/`. The game engine and its data don't. You need your own mirror folder containing `playgta5.com/b/8b0b5899ed/game.wasm` and `playgta5.com/data/`. Wherever a file exists in both places, the launcher's copy in `site/` is used.

## Usage
1. Open the app and click **Choose…**. You can pick the `mirror` folder, the `mirror/playgta5.com` folder, or the folder that contains `mirror/`.
2. Click **Start**. On macOS and Windows the game opens inside the launcher window. On Linux it opens in your browser. Use Chrome or Edge there, because the game needs WebGPU.

The game screen has buttons for **Launcher** (back), **Reload**, **Open in browser** and **Full screen**. You can switch the **Play in app** toggle off to always use the browser instead.

| OS | In-app engine | Notes |
| --- | --- | --- |
| macOS | WKWebView | Needs a macOS version whose WebKit has WebGPU (checked on macOS 27) |
| Windows | WebView2 | Needs the WebView2 Runtime (included with Windows 10/11). Without it, the app falls back to the browser |
| Linux | none | Always uses the browser |

If the webview can't run the game, a banner appears with an Open in browser button. The app remembers the folder, port and play mode. If the port is busy, it uses a free one and shows the address.

## Build
Requires Flutter 3.44+. Build each OS on that OS:
```
flutter pub get
flutter build windows   # build/windows/x64/runner/Release/
flutter build macos     # build/macos/Build/Products/Release/playgta5_launcher.app
flutter build linux     # build/linux/x64/release/bundle/
```
On Linux you need the usual Flutter desktop packages: `clang cmake ninja-build pkg-config libgtk-3-dev`.

## Development
```
flutter test                                  # server + range + validator tests
dart run tool/serve.dart <mirror/playgta5.com> 8000   # run the server without the UI
```

| Path | Purpose |
| --- | --- |
| `lib/server/mirror_server.dart` | HTTP server: COOP/COEP/CORP headers, byte ranges, `POST /data/batch` |
| `lib/server/site_files.dart` | Maps each URL path to its file in `site/` |
| `site/` | The site's web files, bundled as Flutter assets |
| `lib/server/range.dart` | `Range` header parsing |
| `lib/services/mirror_validator.dart` | Finds the site root (needs `game.wasm` + `data/`) |
| `lib/services/settings.dart` | Saves the folder and port |
| `lib/ui/launcher_page.dart` | The launcher screen |
| `lib/ui/game_page.dart` | In-app game view (embedded webview) |
| `lib/services/in_app_support.dart` | Detects whether in-app play works on this OS |

The macOS app sandbox is turned off so the app can still read the saved folder after a relaunch. Because of that, it can't be distributed through the Mac App Store.
