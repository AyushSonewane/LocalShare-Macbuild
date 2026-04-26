import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/discovery_service.dart';
import 'services/file_transfer_service.dart';
import 'services/settings_service.dart';
import 'services/share_intent_service.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';
import 'utils/fun_names.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load persisted settings before anything renders
  final settings = SettingsService();
  await settings.load();

  // Request permissions on Android
  if (Platform.isAndroid) {
    await [
      Permission.storage,
      Permission.photos,
      Permission.videos,
      Permission.audio,
      Permission.nearbyWifiDevices,
    ].request();
  }

  // Ensure a stable device ID exists
  final prefs = await SharedPreferences.getInstance();
  String deviceId = prefs.getString('device_id') ?? '';
  if (deviceId.isEmpty) {
    deviceId = DiscoveryService.generateId();
    await prefs.setString('device_id', deviceId);
  }

  // Generate a fun display name once and persist it
  if ((prefs.getString('device_fun_name') ?? '').isEmpty) {
    final funName = pickFunName(deviceId);
    await prefs.setString('device_fun_name', funName);
  }
  // Reload settings so the fun name is reflected
  await settings.load();

  // Services — initialized lazily by SplashScreen
  final discoveryService = DiscoveryService();
  final transferService = FileTransferService(
    discoveryService: discoveryService,
    settingsService: settings,
  );
  final shareIntentService = ShareIntentService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: discoveryService),
        ChangeNotifierProvider.value(value: transferService),
        ChangeNotifierProvider.value(value: shareIntentService),
      ],
      child: const TcpFileShareApp(),
    ),
  );
}

class TcpFileShareApp extends StatelessWidget {
  const TcpFileShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<SettingsService>().themeMode;
    return MaterialApp(
      title: 'LocalShare',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: const SplashScreen(),
    );
  }
}
