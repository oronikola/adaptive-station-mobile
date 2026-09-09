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

/// Everything gateway-sender mode needs from the backend — the claim/send
/// loop's data layer, parallel to ParentRepository. See IP-007 (adaptive-
/// station) for the server-side design this talks to.
class GatewaySenderRepository {
  GatewaySenderRepository({GatewayApiClient? client})
    : _client = client ?? GatewayApiClient();

  final GatewayApiClient _client;
  String? _deviceId;
  String? _deviceLabel;

  String? get deviceLabel => _deviceLabel;

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

  /// Persists a token/profile already obtained from the shared login
  /// screen's unified login call — mirrors ParentRepository.saveSession().
  Future<void> saveSession(String token, Map<String, dynamic>? profile) async {
    await _client.saveToken(token);
    _deviceId = profile?['id'] as String?;
    _deviceLabel = profile?['label'] as String?;
    if (profile != null) {
      await _client.saveDeviceProfile(profile);
    }
  }

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

  Future<List<GatewayMessage>> claim({int batchSize = 20}) async {
    final response = await _client.post('/claim', {'batch_size': batchSize});
    final messages = (response['messages'] as List).cast<Map<String, dynamic>>();
    return messages.map(GatewayMessage.fromJson).toList();
  }

  Future<void> reportSent(String messageId) =>
      _client.post('/messages/$messageId/status', {'status': 'sent'});

  Future<void> reportFailed(String messageId, String error) => _client.post(
    '/messages/$messageId/status',
    {'status': 'failed', 'error': error},
  );

  /// Reported once the carrier's delivery report arrives via
  /// [SimSmsSender.deliveryReports] — independent of, and usually later
  /// than, the original [reportSent] call for the same message.
  Future<void> reportDelivered(String messageId) =>
      _client.post('/messages/$messageId/status', {'status': 'delivered'});
}
