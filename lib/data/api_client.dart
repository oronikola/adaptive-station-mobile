import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Points at the Laravel dev server by default — 10.0.0.102 is how the Android
/// emulator reaches the host machine's localhost. Override for a real device
/// or production with: flutter run --dart-define=API_BASE_URL=https://...
abstract final class ApiConfig {
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://station.adaptivehub.app/api/v1/parent',
  );

  /// Reverb connection details for the live tap-update WebSocket — the host
  /// is derived from [baseUrl] (same dev machine) rather than duplicated as
  /// its own dart-define, so the two can't drift apart. Port and app key
  /// default to match adaptive-station's local .env; override with
  /// --dart-define=REVERB_PORT=... / REVERB_APP_KEY=... if that changes.
  static String get realtimeHost => Uri.parse(baseUrl).host;

  /// wss:// for a real https:// deployment (Reverb sits behind an Nginx
  /// TLS-terminating reverse proxy there — plaintext ws:// to a public host
  /// is blocked by Android's default cleartext-traffic policy anyway), ws://
  /// only for local http:// dev.
  static String get realtimeScheme =>
      Uri.parse(baseUrl).scheme == 'https' ? 'wss' : 'ws';

  static const realtimePort = int.fromEnvironment(
    'REVERB_PORT',
    defaultValue: 443,
  );

  static const realtimeAppKey = String.fromEnvironment(
    'REVERB_APP_KEY',
    defaultValue: 'aopushzmwi0wxxreepdh',
  );

  /// [baseUrl] is scoped to `/api/v1/parent` — endpoints outside that scope
  /// (the shared login, and gateway-sender mode's `/api/v1/device/sms/*`)
  /// need the bare `/api/v1` root instead. Derived from [baseUrl] rather
  /// than its own dart-define so the two can never drift apart.
  static String get apiRoot {
    final uri = Uri.parse(baseUrl);
    final segments = List<String>.from(uri.pathSegments)..removeLast();
    return uri.replace(pathSegments: segments).toString();
  }
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Thin JSON/bearer-token wrapper around package:http — holds the parent's
/// access token in secure storage (Keychain/Keystore) so it survives app
/// restarts without living in plain SharedPreferences.
class ApiClient {
  ApiClient({http.Client? httpClient, FlutterSecureStorage? storage})
    : _http = httpClient ?? http.Client(),
      _storage = storage ?? const FlutterSecureStorage();

  final http.Client _http;
  final FlutterSecureStorage _storage;
  static const _tokenKey = 'parent_access_token';
  static const _profileKey = 'parent_profile';

  Future<String?> get storedToken => _storage.read(key: _tokenKey);

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  /// Persisted alongside the token so a resumed session (app reopened with
  /// a still-valid token, no fresh /login call) still has the parent's own
  /// id/name/email available — needed for both the account screen and
  /// opening this parent's private realtime channel.
  Future<void> saveParentProfile(Map<String, dynamic> profile) =>
      _storage.write(key: _profileKey, value: jsonEncode(profile));

  Future<Map<String, dynamic>?> readParentProfile() async {
    final raw = await _storage.read(key: _profileKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> clearToken() => Future.wait([
    _storage.delete(key: _tokenKey),
    _storage.delete(key: _profileKey),
  ]);

  Future<Map<String, dynamic>> get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) => _send('POST', path, body);

  Future<Map<String, dynamic>> patch(
    String path, [
    Map<String, dynamic>? body,
  ]) => _send('PATCH', path, body);

  Future<Map<String, dynamic>> delete(
    String path, [
    Map<String, dynamic>? body,
  ]) => _send('DELETE', path, body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final token = await storedToken;
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');
    final headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final encodedBody = body == null ? null : jsonEncode(body);

    const timeout = Duration(seconds: 15);
    http.Response? response;
    Object? networkError;

    // A cold-started app's very first request can occasionally race
    // Android's network stack still coming up right after launch — one
    // quick retry absorbs that transient blip instead of surfacing a
    // "could not reach the server" error the user can do nothing about.
    for (var attempt = 0; attempt < 2 && response == null; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 800));
      try {
        switch (method) {
          case 'GET':
            response = await _http.get(uri, headers: headers).timeout(timeout);
          case 'POST':
            response = await _http
                .post(uri, headers: headers, body: encodedBody)
                .timeout(timeout);
          case 'PATCH':
            response = await _http
                .patch(uri, headers: headers, body: encodedBody)
                .timeout(timeout);
          case 'DELETE':
            response = await _http
                .delete(uri, headers: headers, body: encodedBody)
                .timeout(timeout);
          default:
            throw ArgumentError('Unsupported HTTP method: $method');
        }
      } on TimeoutException catch (e) {
        networkError = e;
      } on http.ClientException catch (e) {
        networkError = e;
      }
    }

    if (response == null) {
      throw ApiException(
        networkError is TimeoutException
            ? 'The server took too long to respond. Check your connection and try again.'
            : 'Could not reach the server. Check your connection and try again.',
      );
    }

    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;

    // A 401 with no token attached means the credentials themselves were
    // rejected (e.g. wrong password at /login) — that's not a session
    // expiring, so the backend's own message ("Invalid school code, email,
    // or password.") is shown instead of a misleading "log in again".
    if (response.statusCode == 401 && token != null) {
      await clearToken();
      throw ApiException(
        'Your session has expired. Please log in again.',
        statusCode: 401,
      );
    }

    if (response.statusCode >= 400) {
      throw ApiException(
        (decoded['message'] as String?) ??
            'Something went wrong. Please try again.',
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }
}
