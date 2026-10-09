import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'services/device.dart';
import 'services/in_app_support.dart';
import 'services/settings.dart';
import 'ui/launcher_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(1280, 800), minimumSize: Size(720, 480), center: true, title: 'playgta5 Launcher'),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final inApp = await InAppSupport.detect();
  runApp(LauncherApp(settings: Settings.create(), inApp: inApp));
}

class LauncherApp extends StatelessWidget {
  const LauncherApp({super.key, required this.settings, required this.inApp});

  final Settings settings;
  final InAppSupport inApp;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'playgta5 Launcher',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: Colors.green, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.green, brightness: Brightness.dark),
      home: LauncherPage(settings: settings, inApp: inApp),
    );
  }
}
