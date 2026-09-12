import 'dart:async';

import 'package:adaptivemobile_station/services/sim_sms_sender.dart';

/// Fake of the native SMS bridge — no MethodChannel, no real radio/SIM. Each
/// call to [send] returns whatever [nextSendResult] holds (defaulting to
/// success), and [emitDeliveryReport] lets a test simulate the carrier's
/// asynchronous delivery report arriving later, the same way the real
/// EventChannel stream would.
class FakeSimSmsSender implements SimSmsSender {
  final _deliveryController = StreamController<SmsDeliveryReport>.broadcast();
  final List<Map<String, String>> sentMessages = [];

  /// Result the next [send] call returns; reset to 'sent' after each call
  /// so a test only needs to override it for the one send it cares about.
  String nextSendResult = 'sent';

  @override
  Stream<SmsDeliveryReport> get deliveryReports => _deliveryController.stream;

  @override
  Future<String> send({
    required int subscriptionId,
    required String phoneNumber,
    required String message,
    required String messageId,
  }) async {
    sentMessages.add({
      'subscriptionId': '$subscriptionId',
      'phoneNumber': phoneNumber,
      'message': message,
      'messageId': messageId,
    });
    final result = nextSendResult;
    nextSendResult = 'sent';
    return result;
  }

  void emitDeliveryReport(String messageId, {required bool delivered}) {
    _deliveryController.add(
      SmsDeliveryReport(messageId: messageId, delivered: delivered),
    );
  }

  void dispose() => _deliveryController.close();
}
