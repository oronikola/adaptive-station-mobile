import 'package:adaptivemobile_station/services/gateway_realtime_service.dart';
import 'package:flutter/foundation.dart';

/// No real socket — just remembers the callback GatewaySenderShell passed to
/// [connect], so a test can call [triggerWakeUp] directly to simulate the
/// server's "sms.queued" broadcast without a real Reverb server.
class FakeGatewayRealtimeService implements GatewayRealtimeService {
  VoidCallback? _onWakeUp;
  bool disconnected = false;

  @override
  void connect(VoidCallback onWakeUp) {
    _onWakeUp = onWakeUp;
  }

  @override
  void disconnect() {
    disconnected = true;
  }

  void triggerWakeUp() => _onWakeUp?.call();
}
