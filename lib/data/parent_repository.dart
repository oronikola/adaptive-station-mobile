import 'api_client.dart';
import 'models.dart';

/// Everything a parent-facing screen needs from the backend. Implemented for
/// real by [ApiParentRepository]; tests use a fake implementation instead of
/// hitting the network (see test/support/fake_parent_repository.dart).
abstract class ParentRepository {
  String? get parentId;
  String? get parentName;
  String? get parentEmail;

  Future<bool> hasStoredSession();

  Future<void> login({
    required String schoolCode,
    required String email,
    required String password,
  });

  Future<void> logout();

  Future<List<Student>> fetchChildren();

  Future<List<AttendanceTap>> fetchAttendance(Student student);

  Future<void> registerDeviceToken(String fcmToken);

  Future<NotificationPreferences> fetchNotificationPreferences();

  Future<void> updateNotificationPreferences(
    NotificationPreferences preferences,
  );

  /// Exchanges a Reverb private-channel subscription request for its auth
  /// signature — see App\Http\Middleware\AuthenticateParent's guard
  /// counterpart ('parent' guard) on the backend, which is what lets this
  /// bearer-token client authorize a channel the same way the REST API does.
  Future<String> authorizeChannel(String channelName, String socketId);
}

class ApiParentRepository implements ParentRepository {
  ApiParentRepository({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;
  String? _parentId;
  String? _parentName;
  String? _parentEmail;

  @override
  String? get parentId => _parentId;

  @override
  String? get parentName => _parentName;

  @override
  String? get parentEmail => _parentEmail;

  @override
  Future<bool> hasStoredSession() async {
    final token = await _client.storedToken;
    if (token == null) return false;

    // A resumed session (app reopened, no fresh /login this run) still
    // needs the parent's id/name/email loaded from where login() persisted
    // them, not just the token.
    if (_parentId == null) {
      final profile = await _client.readParentProfile();
      _parentId = profile?['id'] as String?;
      _parentName = profile?['name'] as String?;
      _parentEmail = profile?['email'] as String?;
    }

    return true;
  }

  @override
  Future<void> login({
    required String schoolCode,
    required String email,
    required String password,
  }) async {
    final response = await _client.post('/login', {
      'school_code': schoolCode,
      'email': email,
      'password': password,
    });

    await _client.saveToken(response['token'] as String);
    final parent = response['parent'] as Map<String, dynamic>?;
    _parentId = parent?['id'] as String?;
    _parentName = parent?['name'] as String?;
    _parentEmail = parent?['email'] as String?;
    if (parent != null) {
      await _client.saveParentProfile(parent);
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
    _parentId = null;
    _parentName = null;
    _parentEmail = null;
  }

  @override
  Future<List<Student>> fetchChildren() async {
    final response = await _client.get('/children');
    final children = (response['children'] as List)
        .cast<Map<String, dynamic>>();
    return children.map(Student.fromJson).toList();
  }

  @override
  Future<List<AttendanceTap>> fetchAttendance(Student student) async {
    final response = await _client.get('/children/${student.id}/attendance');
    final events = (response['data'] as List).cast<Map<String, dynamic>>();
    return events
        .map((event) => AttendanceTap.fromJson(event, student))
        .toList();
  }

  @override
  Future<void> registerDeviceToken(String fcmToken) => _client.post(
    '/device-tokens',
    {'fcm_token': fcmToken, 'platform': 'android'},
  );

  @override
  Future<NotificationPreferences> fetchNotificationPreferences() async {
    final response = await _client.get('/notification-preferences');
    return NotificationPreferences.fromJson(
      response['preferences'] as Map<String, dynamic>,
    );
  }

  @override
  Future<void> updateNotificationPreferences(
    NotificationPreferences preferences,
  ) => _client.patch('/notification-preferences', preferences.toJson());

  @override
  Future<String> authorizeChannel(String channelName, String socketId) async {
    final response = await _client.post('/broadcasting/auth', {
      'channel_name': channelName,
      'socket_id': socketId,
    });
    return response['auth'] as String;
  }
}
