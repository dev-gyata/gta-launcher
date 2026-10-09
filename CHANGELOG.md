<!-- markdownlint-disable MD024 --><!-- each release repeats the Added/Changed/Fixed headings -->
# Changelog

All notable changes to the playgta5 Launcher. Each release on the [Releases page](https://github.com/dev-gyata/gta-launcher/releases) uses its section below as its description.

## [Unreleased]

## [1.4.2] - 2026-10-09

### Added

- **Engine build** in Game options › Advanced: 32-bit or 64-bit (and Automatic on desktop). On phones and tablets **32-bit is selected by default**; on Android you can switch to 64-bit, on iPhone/iPad only 32-bit runs.

## [1.4.1] - 2026-10-09

### Fixed

- iPad: the game now opens in landscape (it stayed in portrait).
- Torrent source: a piece requested while the launcher was still checking its download cache after a restart could wait forever. Such pieces are now read straight from disk.

## [1.4.0] - 2026-10-09

### Added

- **iPad and iPhone app** (iOS/iPadOS 26+). The game plays inside the app. Game data comes from an HTTP mirror, a folder you pick (remembered across launches), or the app's own **game** folder, filled with the Files app or Finder. Distributed unsigned; see the README for sideloading.
- **Safari support** on Mac. Browsers without 64-bit WebAssembly (Safari and every iOS browser) get a 32-bit build of the engine, converted once in the browser and cached. Your game files are not modified.
- Sideloading guides for iOS and Android in the README.

### Changed

- Android uses the 32-bit engine build by default. In testing it ran steadier and loaded faster.
- Release builds are much faster with warm caches (Windows about 28 → 10 minutes, macOS 13 → 6). A release can now be published from an earlier verified build without rebuilding.

### Fixed

- Safari: shaders that clip geometry failed to compile, and draws with an unused resource group were rejected (a black world).

## [1.3.0] - 2026-10-09

### Added

- **Android app**: the launcher serves the game on the device and opens it in Chrome, with a "Game server running · Stop" notification while you play. The server stops by itself when the app is closed or the game tab has been gone for 5 minutes.
- **On-screen touch controls** on phones and tablets (move stick, drag to look, the full button set). They hide while a controller is connected.
- **Game options**: start mode, new game, graphics profile, shadows, render scale, frame rate cap, FPS counter, controller and touch modes, camera sensitivity, skip the device check.
- Android folder picker with **All files access**.
- **Turn on WebGPU in Chrome** helper on Android.
- A device check before loading, naming what a device lacks (64-bit WebAssembly, WebGPU, BC textures) instead of a black screen.
- Android app icon.

### Changed

- Start-menu buttons are larger on touch screens.

## [1.2.0] - 2026-10-09

### Added

- **Full controller support** through the game's own gamepad layer: analog sticks and triggers, the console button layout (weapon and character wheels), controller button prompts, and vibration.

## [1.1.0] - 2026-10-08

### Added

- Controller support, mapped to keyboard and mouse.
- An original launcher logo and app icons.

## [1.0.0] - 2026-10-08

### Added

- First release for Windows, macOS (Apple Silicon) and Linux.
- Game sources: a local folder, an HTTP mirror, or a magnet link (bundled torrent engine that downloads only the pieces the game asks for, ZIP mirrors supported).
- In-app play on macOS and Windows; browser play on Linux.

[Unreleased]: https://github.com/dev-gyata/gta-launcher/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/dev-gyata/gta-launcher/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/dev-gyata/gta-launcher/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/dev-gyata/gta-launcher/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/dev-gyata/gta-launcher/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/dev-gyata/gta-launcher/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/dev-gyata/gta-launcher/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/dev-gyata/gta-launcher/releases/tag/v1.0.0
