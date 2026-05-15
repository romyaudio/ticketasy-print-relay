import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'dart:io';

import 'screens/home_screen.dart';
import 'services/local_server.dart';
import 'services/config_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Single instance check - prevent multiple agents running
  final lockFile = File('${Directory.systemTemp.path}/ticketventas_print.lock');
  try {
    if (await lockFile.exists()) {
      final pid = await lockFile.readAsString();
      try {
        final result = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
        if ((result.stdout as String).contains(pid.trim())) {
          exit(0);
        }
      } catch (_) {}
    }
    await lockFile.writeAsString('${pid}');
  } catch (_) {}

  // Window manager setup
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(420, 580),
    minimumSize: Size(380, 500),
    center: true,
    title: 'Ticket Ventas Print',
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });

  // Auto-start setup
  launchAtStartup.setup(
    appName: 'Ticket Ventas Print',
    appPath: Platform.resolvedExecutable,
  );

  runApp(const TicketVentasPrintApp());
}

class TicketVentasPrintApp extends StatelessWidget {
  const TicketVentasPrintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ticket Ventas Print',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1227DA),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFE7EAFD),
        useMaterial3: true,
        fontFamily: 'Segoe UI',
      ),
      home: const MainWindow(),
    );
  }
}

class MainWindow extends StatefulWidget {
  const MainWindow({super.key});

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> with WindowListener {
  final SystemTray _systemTray = SystemTray();
  final LocalPrintServer _server = LocalPrintServer();
  final ConfigService _configService = ConfigService();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initApp();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _server.stop();
    super.dispose();
  }

  /// Minimize to tray instead of closing
  @override
  void onWindowClose() async {
    await windowManager.setPreventClose(true);
    await windowManager.hide();
  }

  Future<void> _initApp() async {
    await _configService.init();

    // Configure printer if already set up
    if (_configService.printerType != null) {
      _server.printerService.configure(
        type: _configService.printerType!,
        address: _configService.printerAddress,
        name: _configService.printerName,
      );
    }

    // System tray
    try {
      await _initSystemTray();
    } catch (e) {
      debugPrint('System tray init failed: $e');
    }

    // Auto-start the local server
    await _server.start();

    setState(() { _initialized = true; });
  }

  Future<void> _initSystemTray() async {
    await _systemTray.initSystemTray(
      title: 'Ticket Ventas Print',
      iconPath: Platform.isWindows ? 'assets/icon.ico' : 'assets/icon.png',
      toolTip: 'Ticket Ventas - Agente de impresión',
    );

    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Abrir', onClicked: (menuItem) async {
        await windowManager.show();
        await windowManager.focus();
      }),
      MenuSeparator(),
      MenuItemLabel(label: 'Salir', onClicked: (menuItem) async {
        await _server.stop();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      }),
    ]);

    await _systemTray.setContextMenu(menu);

    _systemTray.registerSystemTrayEventHandler((eventName) async {
      if (eventName == kSystemTrayEventClick || eventName == kSystemTrayEventDoubleClick) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return HomeScreen(
      server: _server,
      configService: _configService,
    );
  }
}
