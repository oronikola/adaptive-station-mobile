import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/parent_repository.dart';

typedef TapRecordedHandler = void Function(Map<String, dynamic> payload);

/// Hand-rolled Pusher-protocol (v7) client — Laravel Reverb speaks the same
/// wire protocol, and the subset actually needed here (connect, subscribe to
/// one private channel, receive one custom event, keep-alive, reconnect) is
/// small enough that this avoids pulling in a full client SDK.
///
/// One instance is kept alive for the whole logged-in session; [connect]
/// re-subscribes if called again with a different parent id (not expected in
/// practice — a parent doesn't change mid-session — but harmless either way).
class RealtimeService {
  RealtimeService({
    required this.host,
    required this.port,
    required this.appKey,
    required this.repository,
  });

  final String host;
  final int port;
  final String appKey;
  final ParentRepository repository;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  String? _socketId;
  String? _parentAccountId;
  TapRecordedHandler? _onTapRecorded;
  bool _disposed = false;

  void connect(String parentAccountId, TapRecordedHandler onTapRecorded) {
    _disposed = false;
    _parentAccountId = parentAccountId;
    _onTapRecorded = onTapRecorded;
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
    debugPrint('Realtime: connecting to $uri');

    final channel = WebSocketChannel.connect(uri);
    _channel = channel;

    // WebSocketChannel.connect() returns immediately and connects lazily —
    // without waiting on `ready` (bounded by a timeout), a connection that
    // never completes (e.g. silently dropped by a firewall, which sends no
    // RST) would leave the stream's onDone/onError never firing, so
    // _scheduleReconnect() would never run again.
    channel.ready
        .timeout(const Duration(seconds: 8))
        .then((_) {
          debugPrint('Realtime: connected');
          _subscription = channel.stream.listen(
            _handleMessage,
            onDone: () {
              debugPrint('Realtime: connection closed');
              _scheduleReconnect();
            },
            onError: (Object e) {
              debugPrint('Realtime: stream error: $e');
              _scheduleReconnect();
            },
            cancelOnError: true,
          );
        })
        .catchError((Object e) {
          debugPrint('Realtime: connect failed: $e');
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
    debugPrint('Realtime: received "$event"');

    switch (event) {
      case 'pusher:connection_established':
        final data = _decodeData(message['data']);
        _socketId = data?['socket_id'] as String?;
        _subscribeToParentChannel();
      case 'pusher:ping':
        _send({'event': 'pusher:pong', 'data': <String, dynamic>{}});
      case 'pusher_internal:subscription_succeeded':
        debugPrint('Realtime: subscribed to ${message['channel']}');
      case 'pusher:error':
        debugPrint('Realtime: server error: ${message['data']}');
      case 'tap.recorded':
        final data = _decodeData(message['data']);
        if (data != null) _onTapRecorded?.call(data);
    }
  }

  /// Pusher wire messages nest their payload as a JSON-encoded *string*
  /// (not a raw object) in the outer message's "data" field.
  Map<String, dynamic>? _decodeData(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) {
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _subscribeToParentChannel() async {
    final socketId = _socketId;
    final parentId = _parentAccountId;
    if (socketId == null || parentId == null) return;

    final channelName = 'private-parent.$parentId';
    try {
      final auth = await repository.authorizeChannel(channelName, socketId);
      _send({
        'event': 'pusher:subscribe',
        'data': {'channel': channelName, 'auth': auth},
      });
    } catch (e) {
      debugPrint('Realtime channel authorization failed: $e');
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
    _socketId = null;
  }
}
