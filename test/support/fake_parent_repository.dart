import 'package:adaptivemobile_station/data/demo_attendance.dart';
import 'package:adaptivemobile_station/data/parent_repository.dart';

/// Serves DemoAttendance's fixture data instantly, with no network calls —
/// keeps widget tests fast, deterministic, and independent of a running
/// backend, while still exercising the real ParentShell/DashboardScreen code.
class FakeParentRepository implements ParentRepository {
  bool loggedIn = true;
  NotificationPreferences preferences = const NotificationPreferences(
    notifyIn: true,
    notifyOut: true,
  );

  /// Left null deliberately — ParentShell only opens the realtime WebSocket
  /// connection when a parent id is present, so widget tests (no real
  /// backend/socket server available) stay fast and offline.
  @override
  String? get parentId => null;

  @override
  String? get parentName => 'Maria Santos';

  @override
  String? get parentEmail => 'maria@example.com';

  @override
  Future<bool> hasStoredSession() async => loggedIn;

  @override
  Future<void> login({
    required String schoolCode,
    required String email,
    required String password,
  }) async {
    loggedIn = true;
  }

  @override
  Future<void> logout() async {
    loggedIn = false;
  }

  @override
  Future<List<Student>> fetchChildren() async => DemoAttendance.children;

  @override
  Future<List<AttendanceTap>> fetchAttendance(Student student) async =>
      DemoAttendance.taps.where((tap) => tap.student.id == student.id).toList();

  @override
  Future<void> registerDeviceToken(String fcmToken) async {}

  @override
  Future<NotificationPreferences> fetchNotificationPreferences() async =>
      preferences;

  @override
  Future<void> updateNotificationPreferences(
    NotificationPreferences preferences,
  ) async {
    this.preferences = preferences;
  }

  @override
  Future<String> authorizeChannel(String channelName, String socketId) async =>
      'fake-auth-signature';
}
