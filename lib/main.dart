import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app_root.dart';
import 'data/gateway_sender_repository.dart';
import 'data/parent_repository.dart';
import 'design/station_theme.dart';
import 'services/push_notification_service.dart';
import 'services/theme_controller.dart';

void main() async {
  // Wrapped in its own zone so an error escaping every other handler below
  // (a raw uncaught async error, not routed through Flutter's own error
  // pipeline) still reaches Crashlytics instead of just crashing silently —
  // this matters most for the gateway-sender fleet, which runs unattended
  // in the field with no debug console anyone will ever see.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await Firebase.initializeApp();

      // Debug builds keep using the console (debugPrint) — Crashlytics
      // collection is for the release builds actually running in the
      // field, where debugPrint output goes nowhere.
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
        !kDebugMode,
      );
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };

      await PushNotificationService.initialize();
      final themeController = ThemeController();
      await themeController.load();
      runApp(
        StationParentApp(
          parentRepository: ApiParentRepository(),
          gatewayRepository: ApiGatewaySenderRepository(),
          themeController: themeController,
        ),
      );
    },
    (error, stack) => FirebaseCrashlytics.instance.recordError(error, stack, fatal: true),
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
