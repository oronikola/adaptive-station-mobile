import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Hand-rolled Pusher-protocol client for the gateway-sender fleet's
/// "sms.queued" wake-up nudge — sibling to [RealtimeService] (see
/// lib/services/realtime_service.dart) but deliberately simpler: it
/// subscribes to a single *public* channel (`sms-gateway`, see
/// App\Events\SmsGatewayWakeUp on the backend), so there's no per-device
/// channel authorization handshake to do at all, unlike the parent app's
/// private `parent.{id}` channel.
///
/// This only ever shortens [GatewaySenderShell]'s poll wait when idle — the
/// actual claim (`POST /claim`, backed by `FOR UPDATE SKIP LOCKED`) stays
/// exactly as it was, so a missed or duplicate wake-up event is harmless:
/// worst case, the device just falls back to its normal poll interval.
class GatewayRealtimeService {
  GatewayRealtimeService({
    required this.host,
    required this.port,
    required this.appKey,
  });

  final String host;
  final int port;
  final String appKey;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  VoidCallback? _onWakeUp;
  bool _disposed = false;

  void connect(VoidCallback onWakeUp) {
    _disposed = false;
    _onWakeUp = onWakeUp;
    _open();
  }

  void _open() {
    if (_disposed) return;

    final uri = Uri(
      scheme: 'ws',
      host: host,
      port: port,
      path: '/app/$appKey',
      queryParameters: {'protocol': '7', 'client': 'flutter', 'version': '1.0'},
    );
    debugPrint('Gateway realtime: connecting to $uri');

    final channel = WebSocketChannel.connect(uri);
    _channel = channel;

    // Same "don't trust connect() alone" reasoning as RealtimeService: a
    // connection silently dropped by a firewall never fires onDone/onError
    // on its own, so the ready-timeout is what guarantees a reconnect gets
    // scheduled either way.
    channel.ready
        .timeout(const Duration(seconds: 8))
        .then((_) {
          debugPrint('Gateway realtime: connected');
          _subscription = channel.stream.listen(
            _handleMessage,
            onDone: () {
              debugPrint('Gateway realtime: connection closed');
              _scheduleReconnect();
            },
            onError: (Object e) {
              debugPrint('Gateway realtime: stream error: $e');
              _scheduleReconnect();
            },
            cancelOnError: true,
          );
        })
        .catchError((Object e) {
          debugPrint('Gateway realtime: connect failed: $e');
          _scheduleReconnect();
        });
  }

  void _handleMessage(dynamic raw) {
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final event = message['event'] as String?;

    switch (event) {
      case 'pusher:connection_established':
        _send({
          'event': 'pusher:subscribe',
          'data': {'channel': 'sms-gateway'},
        });
      case 'pusher:ping':
        _send({'event': 'pusher:pong', 'data': <String, dynamic>{}});
      case 'pusher_internal:subscription_succeeded':
        debugPrint('Gateway realtime: subscribed to ${message['channel']}');
      case 'sms.queued':
        _onWakeUp?.call();
    }
  }

  void _send(Map<String, dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _open);
  }

  void disconnect() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
  }
}
