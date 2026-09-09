import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';

/// Bearer-token JSON wrapper for gateway-sender mode's `/api/v1/device/sms/*`
/// endpoints — same shape as [ApiClient], deliberately a separate class
/// (own storage keys, own base path) rather than generalizing [ApiClient],
/// since a phone is never logged in as both a parent and a gateway device
/// at once and the two shouldn't share a token slot.
class GatewayApiClient {
  GatewayApiClient({http.Client? httpClient, FlutterSecureStorage? storage})
    : _http = httpClient ?? http.Client(),
      _storage = storage ?? const FlutterSecureStorage();

  final http.Client _http;
  final FlutterSecureStorage _storage;
  static const _tokenKey = 'gateway_device_token';
  static const _profileKey = 'gateway_device_profile';

  Future<String?> get storedToken => _storage.read(key: _tokenKey);

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<void> saveDeviceProfile(Map<String, dynamic> profile) =>
      _storage.write(key: _profileKey, value: jsonEncode(profile));

  Future<Map<String, dynamic>?> readDeviceProfile() async {
    final raw = await _storage.read(key: _profileKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> clearToken() => Future.wait([
    _storage.delete(key: _tokenKey),
    _storage.delete(key: _profileKey),
  ]);

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
  ]) => _send('POST', path, body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final token = await storedToken;
    final uri = Uri.parse('${ApiConfig.apiRoot}/device/sms$path');
    final headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final encodedBody = body == null ? null : jsonEncode(body);

    const timeout = Duration(seconds: 15);
    http.Response? response;
    Object? networkError;

    for (var attempt = 0; attempt < 2 && response == null; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 800));
      try {
        response = switch (method) {
          'POST' => await _http
              .post(uri, headers: headers, body: encodedBody)
              .timeout(timeout),
          _ => throw ArgumentError('Unsupported HTTP method: $method'),
        };
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

    if (response.statusCode == 401 && token != null) {
      await clearToken();
      throw ApiException(
        'This device has been logged out. Please log in again.',
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
