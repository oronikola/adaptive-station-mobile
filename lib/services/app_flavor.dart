import 'package:flutter/services.dart';

enum AppFlavor { parent, gateway }

/// Which Gradle product flavor this binary was actually built as — read
/// straight from native BuildConfig.FLAVOR (see MainActivity.kt's
/// "getFlavor" handler) rather than a --dart-define, so it can never drift
/// out of sync with which manifest/permissions the build actually merged.
class AppFlavorService {
  static const _channel = MethodChannel('adaptivestation.sms/channel');
  static AppFlavor? _cached;

  static Future<AppFlavor> resolve() async {
    final cached = _cached;
    if (cached != null) return cached;

    try {
      final name = await _channel.invokeMethod<String>('getFlavor');
      final resolved = name == 'gateway' ? AppFlavor.gateway : AppFlavor.parent;
      _cached = resolved;
      return resolved;
    } catch (_) {
      // Channel unavailable (non-Android platform, or a plain unflavored
      // build) — default to `parent`, the flavor with permissions stripped,
      // so an unrecognized build fails toward "blocks gateway login" rather
      // than "silently tries to send SMS with no permission."
      const fallback = AppFlavor.parent;
      _cached = fallback;
      return fallback;
    }
  }
}
