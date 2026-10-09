import 'dart:io';

/// macOS, Windows or Linux: the launcher runs in its own window and can use
/// the torrent engine.
bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Android or iOS: no window management, the game is shown full screen, and
/// the server stops when the player leaves the game.
bool get isMobile => Platform.isAndroid || Platform.isIOS;
