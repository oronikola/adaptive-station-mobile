import 'package:adaptivemobile_station/data/gateway_sender_repository.dart';

/// In-memory fake of the backend's claim/report contract (see IP-007 and
/// App\Http\Controllers\Api\Device\SmsGatewayController on the server) —
/// keeps GatewaySenderShell's tests fast, deterministic, and independent of
/// a running backend, mirroring test/support/fake_parent_repository.dart's
/// approach for the parent side.
class FakeGatewaySenderRepository implements GatewaySenderRepository {
  FakeGatewaySenderRepository({List<GatewayMessage> queue = const []})
    : _queue = List.of(queue);

  final List<GatewayMessage> _queue;
  final List<String> reportedSent = [];
  final List<(String, String)> reportedFailed = [];
  final List<String> reportedDelivered = [];
  final List<int?> reportedSentSimSlots = [];
  final List<int?> reportedFailedSimSlots = [];
  final List<int?> reportedDeliveredSimSlots = [];
  int claimCalls = 0;
  bool loggedIn = true;

  /// Set to make the next claim() call throw instead of returning normally
  /// — used to exercise the 401/logout path without a real HTTP round-trip.
  Object? nextClaimError;

  void enqueue(GatewayMessage message) => _queue.add(message);

  @override
  String? get deviceLabel => 'Test Gateway Device';

  @override
  Future<bool> hasStoredSession() async => loggedIn;

  @override
  Future<void> saveSession(String token, Map<String, dynamic>? profile) async {
    loggedIn = true;
  }

  @override
  Future<void> logout() async {
    loggedIn = false;
  }

  @override
  Future<List<GatewayMessage>> claim({int batchSize = 20}) async {
    claimCalls++;
    final error = nextClaimError;
    if (error != null) {
      nextClaimError = null;
      throw error;
    }

    // Deliberately ignores batchSize and hands out one message per call
    // (rather than draining the whole queue to whichever SIM asks first) —
    // this is what lets the "two SIMs handle messages independently" test
    // be deterministic instead of a race between which SIM's loop happens
    // to call claim() first.
    final taken = _queue.take(1).toList();
    _queue.removeRange(0, taken.length);
    return taken;
  }

  @override
  Future<void> reportSent(String messageId, {int? simSlot}) async {
    reportedSent.add(messageId);
    reportedSentSimSlots.add(simSlot);
  }

  @override
  Future<void> reportFailed(
    String messageId,
    String error, {
    int? simSlot,
  }) async {
    reportedFailed.add((messageId, error));
    reportedFailedSimSlots.add(simSlot);
  }

  @override
  Future<void> reportDelivered(String messageId, {int? simSlot}) async {
    reportedDelivered.add(messageId);
    reportedDeliveredSimSlots.add(simSlot);
  }
}
