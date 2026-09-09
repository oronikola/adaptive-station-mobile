import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'app_root.dart';
import 'data/gateway_sender_repository.dart';
import 'data/parent_repository.dart';
import 'design/station_theme.dart';
import 'services/push_notification_service.dart';
import 'services/theme_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await PushNotificationService.initialize();
  final themeController = ThemeController();
  await themeController.load();
  runApp(
    StationParentApp(
      parentRepository: ApiParentRepository(),
      gatewayRepository: GatewaySenderRepository(),
      themeController: themeController,
    ),
  );
}

class StationParentApp extends StatelessWidget {
  const StationParentApp({
    super.key,
    required this.parentRepository,
    required this.gatewayRepository,
    required this.themeController,
  });
  final ParentRepository parentRepository;
  final GatewaySenderRepository gatewayRepository;
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: themeController,
    builder: (context, mode, _) => MaterialApp(
      title: 'Adaptive Station',
      debugShowCheckedModeBanner: false,
      theme: StationTheme.light,
      darkTheme: StationTheme.dark,
      themeMode: mode,
      home: AppRoot(
        parentRepository: parentRepository,
        gatewayRepository: gatewayRepository,
        themeController: themeController,
      ),
    ),
  );
}
