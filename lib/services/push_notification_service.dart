import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/parent_repository.dart';

/// Must be a top-level (or static) function — the OS relaunches the Flutter
/// engine in the background to run it when a push arrives while the app is
/// killed/backgrounded, so it can't close over any app state.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Background tap notification received: ${message.messageId}');
}

/// Owns FCM setup for the parent app: permission request, the Android
/// notification channel, and the device token (registered with the backend
/// via [attachRepository]/LoginScreen, see ApiParentRepository.
/// registerDeviceToken). Call [initialize] once, after
/// `Firebase.initializeApp()`.
class PushNotificationService {
  PushNotificationService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  static String? _lastKnownToken;
  static ParentRepository? _repository;

  /// Id must match android:value of the default_notification_channel_id
  /// meta-data in AndroidManifest.xml — that's what routes FCM's
  /// automatic background/killed-state notification display into this
  /// channel instead of an OEM fallback, which is what was silently
  /// suppressing the heads-up banner (message still arrived, no popup).
  static const AndroidNotificationChannel _tapAlertsChannel =
      AndroidNotificationChannel(
        'tap_alerts_channel',
        'Tap alerts',
        description: 'Notifications when your child taps IN or OUT at school.',
        importance: Importance.high,
      );

  static String? get lastKnownToken => _lastKnownToken;

  /// Called once a parent is logged in, so a later token refresh can be
  /// re-registered with the backend without the caller having to remember
  /// to wire that up itself.
  static void attachRepository(ParentRepository repository) =>
      _repository = repository;

  static void detachRepository() => _repository = null;

  static Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_tapAlertsChannel);

    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint(
      'Notification permission status: ${settings.authorizationStatus}',
    );

    _lastKnownToken = await _messaging.getToken();
    debugPrint('FCM device token: $_lastKnownToken');

    _messaging.onTokenRefresh.listen((refreshedToken) {
      _lastKnownToken = refreshedToken;
      debugPrint('FCM device token refreshed: $refreshedToken');
      _repository?.registerDeviceToken(refreshedToken).catchError((_) {});
    });

    FirebaseMessaging.onMessage.listen((message) {
      debugPrint(
        'Foreground tap notification received: ${message.notification?.title}',
      );
    });
  }
}
