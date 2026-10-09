import 'dart:convert';

/// How the game starts.
enum StartMode {
  /// The game's own start menu asks (Story Mode or Sandbox Mode).
  ask,
  story,
  sandbox,

  /// Sandbox Mode on the env_test level ("GTA VI Map").
  sandboxTestMap,
}

/// The low-memory profile (smaller textures, no shadows, fewer threads).
enum GraphicsProfile {
  /// On when the browser reports 4 GB of memory or less.
  auto,
  low,
  full,
}

enum FrameCap { fps60, fps30, uncapped }

enum ControllerMode {
  /// The game's own gamepad support (analog, controller prompts, rumble).
  native,

  /// Controller translated into keyboard and mouse input.
  keyboard,
  off,
}

/// Which build of the engine runs: 64-bit WebAssembly memory, or game.wasm lowered to 32-bit memory (converted once in the browser).
enum EngineBuild {
  /// 32-bit on Android and where 64-bit WebAssembly is missing (Safari, iOS); 64-bit elsewhere.
  auto,
  mem64,
  mem32,
}

enum TouchControls {
  /// Phones and tablets only.
  auto,
  on,
  off,
}

/// Game settings chosen in the launcher, passed to the game page as URL
/// options (site/homepage.html reads them with `q.get(...)`).
class GameOptions {
  const GameOptions({
    this.startMode = StartMode.ask,
    this.newGame = false,
    this.graphics = GraphicsProfile.auto,
    this.lowMemoryShadows = false,
    this.renderScale = 1.0,
    this.frameCap = FrameCap.fps60,
    this.showFps = false,
    this.controller = ControllerMode.native,
    this.lookSensitivity = 1.0,
    this.touch = TouchControls.auto,
    this.skipDeviceCheck = false,
    this.engineBuild = EngineBuild.auto,
  });

  final StartMode startMode;

  /// Story Mode: start a new game instead of loading the last save.
  final bool newGame;
  final GraphicsProfile graphics;

  /// Keep shadows (at the lowest level) in the low-memory profile.
  final bool lowMemoryShadows;

  /// Fraction of the window's resolution the game renders at (0.5 to 1).
  final double renderScale;
  final FrameCap frameCap;
  final bool showFps;
  final ControllerMode controller;

  /// Camera speed for the right stick (keyboard mapping) and touch look.
  final double lookSensitivity;
  final TouchControls touch;

  /// Start even when the page finds the device lacks something the game needs.
  final bool skipDeviceCheck;
  final EngineBuild engineBuild;

  static const defaults = GameOptions();

  /// The URL query for the game page; empty when everything is default.
  Map<String, String> get query => {
    if (startMode == StartMode.story) 'mode': 'story',
    if (startMode == StartMode.sandbox || startMode == StartMode.sandboxTestMap) 'mode': 'sandbox',
    if (startMode == StartMode.sandboxTestMap) 'map': 'env_test',
    if (newGame && (startMode == StartMode.story || startMode == StartMode.ask)) 'newgame': '1',
    if (graphics == GraphicsProfile.low) 'low': '1',
    if (graphics == GraphicsProfile.full) 'low': '0',
    if (lowMemoryShadows && graphics != GraphicsProfile.full) 'shadows': '1',
    if (renderScale != 1.0) 'scale': _number(renderScale),
    if (frameCap == FrameCap.fps30) 'fps': '30',
    if (frameCap == FrameCap.uncapped) 'fps': '0',
    if (showFps) 'showfps': '1',
    if (controller == ControllerMode.keyboard) 'pad': 'keys',
    if (controller == ControllerMode.off) 'pad': '0',
    if (lookSensitivity != 1.0) 'padsens': _number(lookSensitivity),
    if (touch == TouchControls.on) 'touch': '1',
    if (touch == TouchControls.off) 'touch': '0',
    if (skipDeviceCheck) 'nocheck': '1',
    if (engineBuild == EngineBuild.mem64) 'mem32': '0',
    if (engineBuild == EngineBuild.mem32) 'mem32': '1',
  };

  /// [url] with these options as its query.
  Uri apply(Uri url) {
    final q = query;
    return q.isEmpty ? url : url.replace(queryParameters: q);
  }

  static String _number(double value) => value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  GameOptions copyWith({
    StartMode? startMode,
    bool? newGame,
    GraphicsProfile? graphics,
    bool? lowMemoryShadows,
    double? renderScale,
    FrameCap? frameCap,
    bool? showFps,
    ControllerMode? controller,
    double? lookSensitivity,
    TouchControls? touch,
    bool? skipDeviceCheck,
    EngineBuild? engineBuild,
  }) => GameOptions(
    startMode: startMode ?? this.startMode,
    newGame: newGame ?? this.newGame,
    graphics: graphics ?? this.graphics,
    lowMemoryShadows: lowMemoryShadows ?? this.lowMemoryShadows,
    renderScale: renderScale ?? this.renderScale,
    frameCap: frameCap ?? this.frameCap,
    showFps: showFps ?? this.showFps,
    controller: controller ?? this.controller,
    lookSensitivity: lookSensitivity ?? this.lookSensitivity,
    touch: touch ?? this.touch,
    skipDeviceCheck: skipDeviceCheck ?? this.skipDeviceCheck,
    engineBuild: engineBuild ?? this.engineBuild,
  );

  String toJson() => jsonEncode({
    'startMode': startMode.name,
    'newGame': newGame,
    'graphics': graphics.name,
    'lowMemoryShadows': lowMemoryShadows,
    'renderScale': renderScale,
    'frameCap': frameCap.name,
    'showFps': showFps,
    'controller': controller.name,
    'lookSensitivity': lookSensitivity,
    'touch': touch.name,
    'skipDeviceCheck': skipDeviceCheck,
    'engineBuild': engineBuild.name,
  });

  /// Unknown or missing values fall back to the defaults, so settings saved
  /// by another version still load.
  factory GameOptions.fromJson(String? source) {
    Map<String, Object?> m;
    try {
      m = source == null ? const {} : (jsonDecode(source) as Map).cast<String, Object?>();
    } on FormatException {
      m = const {};
    }
    T pick<T extends Enum>(List<T> values, String key, T fallback) =>
        values.where((v) => v.name == m[key]).firstOrNull ?? fallback;
    double number(String key, double fallback, double min, double max) {
      final v = m[key];
      return v is num ? v.toDouble().clamp(min, max) : fallback;
    }

    bool flag(String key) => m[key] == true;
    return GameOptions(
      startMode: pick(StartMode.values, 'startMode', StartMode.ask),
      newGame: flag('newGame'),
      graphics: pick(GraphicsProfile.values, 'graphics', GraphicsProfile.auto),
      lowMemoryShadows: flag('lowMemoryShadows'),
      renderScale: number('renderScale', 1.0, 0.5, 1.0),
      frameCap: pick(FrameCap.values, 'frameCap', FrameCap.fps60),
      showFps: flag('showFps'),
      controller: pick(ControllerMode.values, 'controller', ControllerMode.native),
      lookSensitivity: number('lookSensitivity', 1.0, 0.25, 3.0),
      touch: pick(TouchControls.values, 'touch', TouchControls.auto),
      skipDeviceCheck: flag('skipDeviceCheck'),
      engineBuild: pick(EngineBuild.values, 'engineBuild', EngineBuild.auto),
    );
  }
}
