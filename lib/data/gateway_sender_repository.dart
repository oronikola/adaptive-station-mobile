import 'gateway_api_client.dart';

class GatewayMessage {
  const GatewayMessage({
    required this.id,
    required this.phoneNumber,
    required this.message,
  });
  final String id;
  final String phoneNumber;
  final String message;

  factory GatewayMessage.fromJson(Map<String, dynamic> json) =>
      GatewayMessage(
        id: json['id'] as String,
        phoneNumber: json['phone_number'] as String,
        message: json['message'] as String,
      );
}

class GatewayClaim {
  const GatewayClaim({required this.messages, required this.capacityExhausted});

  final List<GatewayMessage> messages;
  final bool capacityExhausted;
}

/// Everything gateway-sender mode needs from the backend — the claim/send
/// loop's data layer, parallel to ParentRepository. Implemented for real by
/// [ApiGatewaySenderRepository]; tests use a fake implementation instead of
/// hitting the network (see test/support/fake_gateway_sender_repository.dart).
/// See IP-007 (adaptive-station) for the server-side design this talks to.
abstract class GatewaySenderRepository {
  String? get deviceLabel;

  Future<bool> hasStoredSession();

  /// Persists a token/profile already obtained from the shared login
  /// screen's unified login call — mirrors ParentRepository.saveSession().
  Future<void> saveSession(String token, Map<String, dynamic>? profile);

  Future<void> logout();

  Future<GatewayClaim> claim({
    int batchSize = 20,
    required int simSlot,
  });

  /// [simSlot] is the phone's own SIM slot index (0 or 1 on a dual-SIM
  /// device) the message was actually sent from — lets the backend track a
  /// daily send cap per SIM, not just per phone (a phone has two
  /// independently-capped carrier SIMs). Optional so a caller that doesn't
  /// know it (shouldn't happen in practice, but keeps the API forgiving)
  /// still gets a valid request.
  Future<void> reportSent(String messageId, {int? simSlot});

  Future<void> reportFailed(String messageId, String error, {int? simSlot});

  /// Reported once the carrier's delivery report arrives via
  /// [SimSmsSender.deliveryReports] — independent of, and usually later
  /// than, the original [reportSent] call for the same message.
  Future<void> reportDelivered(String messageId, {int? simSlot});
}

class ApiGatewaySenderRepository implements GatewaySenderRepository {
  ApiGatewaySenderRepository({GatewayApiClient? client})
    : _client = client ?? GatewayApiClient();

  final GatewayApiClient _client;
  String? _deviceId;
  String? _deviceLabel;

  @override
  String? get deviceLabel => _deviceLabel;

  @override
  Future<bool> hasStoredSession() async {
    final token = await _client.storedToken;
    if (token == null) return false;

    if (_deviceId == null) {
      final profile = await _client.readDeviceProfile();
      _deviceId = profile?['id'] as String?;
      _deviceLabel = profile?['label'] as String?;
    }

    return true;
  }

  @override
  Future<void> saveSession(String token, Map<String, dynamic>? profile) async {
    await _client.saveToken(token);
    _deviceId = profile?['id'] as String?;
    _deviceLabel = profile?['label'] as String?;
    if (profile != null) {
      await _client.saveDeviceProfile(profile);
    }
  }

  @override
  Future<void> logout() async {
    try {
      await _client.post('/logout');
    } catch (_) {
      // The token may already be invalid/expired server-side — local
      // logout should still succeed regardless.
    }
    await _client.clearToken();
    _deviceId = null;
    _deviceLabel = null;
  }

  @override
  Future<GatewayClaim> claim({
    int batchSize = 20,
    required int simSlot,
  }) async {
    final response = await _client.post('/claim', {
      'batch_size': batchSize,
      'sim_slot': simSlot,
    });
    final messages = (response['messages'] as List).cast<Map<String, dynamic>>();
    return GatewayClaim(
      messages: messages.map(GatewayMessage.fromJson).toList(),
      capacityExhausted: response['capacity_exhausted'] as bool? ?? false,
    );
  }

  @override
  Future<void> reportSent(String messageId, {int? simSlot}) => _client.post(
    '/messages/$messageId/status',
    {'status': 'sent', if (simSlot != null) 'sim_slot': simSlot},
  );

  @override
  Future<void> reportFailed(String messageId, String error, {int? simSlot}) =>
      _client.post('/messages/$messageId/status', {
        'status': 'failed',
        'error': error,
        if (simSlot != null) 'sim_slot': simSlot,
      });

  @override
  Future<void> reportDelivered(String messageId, {int? simSlot}) =>
      _client.post('/messages/$messageId/status', {
        'status': 'delivered',
        if (simSlot != null) 'sim_slot': simSlot,
      });
}
