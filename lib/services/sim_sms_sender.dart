import 'package:flutter/services.dart';

/// One carrier delivery report, pushed from the native side independently
/// of (and typically well after) the original [SimSmsSender.send] call that
/// sent it — see MainActivity.kt's docblock for why this can't reuse a
/// simple request/response call.
class SmsDeliveryReport {
  const SmsDeliveryReport({required this.messageId, required this.delivered});
  final String messageId;
  final bool delivered;
}

/// Bridges to MainActivity.kt's native SmsManager handler — gateway-sender
/// mode only. An interface (not the static class this used to be) so
/// GatewaySenderShell can be tested against a fake implementation instead of
/// a real platform channel — see test/support/fake_sim_sms_sender.dart.
/// [MethodChannelSimSmsSender] is the one real implementation, used
/// everywhere the app actually runs.
abstract interface class SimSmsSender {
  /// Carrier delivery reports as they arrive, tagged with the sms_outbox
  /// message id passed to [send] — a broadcast stream since the shell
  /// listens to it once for the whole screen's lifetime, not per-message.
  Stream<SmsDeliveryReport> get deliveryReports;

  /// Returns `'sent'` on success, or `'error: <reason>'` — never throws for
  /// an ordinary send failure (radio off, no service, etc.), only for a
  /// platform-channel-level problem. [messageId] (the sms_outbox row's id)
  /// is threaded through to the native side so a later delivery report can
  /// be tagged with it on [deliveryReports] — it never needs to be invented
  /// or tracked in a separate map on the Dart side.
  Future<String> send({
    required int subscriptionId,
    required String phoneNumber,
    required String message,
    required String messageId,
  });
}

/// Ported from the standalone dual_sim_sms_Android14 app this replaces; the
/// channel name changed (namespaced to this app) but the contract is the
/// same. Method bodies are unchanged from the static class this replaced —
/// only the wrapping (static -> instance, behind the [SimSmsSender]
/// interface) is new.
class MethodChannelSimSmsSender implements SimSmsSender {
  const MethodChannelSimSmsSender();

  static const _channel = MethodChannel('adaptivestation.sms/channel');
  static const _deliveryChannel = EventChannel('adaptivestation.sms/delivery');

  @override
  Stream<SmsDeliveryReport> get deliveryReports =>
      _deliveryChannel.receiveBroadcastStream().map((event) {
        final map = Map<String, dynamic>.from(event as Map);
        return SmsDeliveryReport(
          messageId: map['messageId'] as String,
          delivered: map['delivered'] as bool,
        );
      });

  @override
  Future<String> send({
    required int subscriptionId,
    required String phoneNumber,
    required String message,
    required String messageId,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('sendSMS', {
        'subscriptionId': subscriptionId,
        'phoneNumber': phoneNumber,
        'message': message,
        'messageId': messageId,
      });
      return result ?? 'error: no result from platform channel';
    } catch (e) {
      return 'error: $e';
    }
  }
}
