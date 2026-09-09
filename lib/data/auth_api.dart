import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';

enum SessionRole { parent, gatewaySender }

class UnifiedLoginResult {
  const UnifiedLoginResult({
    required this.role,
    required this.token,
    this.parentProfile,
    this.deviceProfile,
  });
  final SessionRole role;
  final String token;
  final Map<String, dynamic>? parentProfile;
  final Map<String, dynamic>? deviceProfile;
}

/// The one shared login call for both account types — see
/// App\Http\Controllers\Api\Auth\LoginController on the backend.
/// `schoolCode` present/absent is what selects parent vs gateway-sender;
/// there's no separate role field in the request.
class AuthApi {
  AuthApi({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<UnifiedLoginResult> login({
    String? schoolCode,
    required String identifier,
    required String password,
  }) async {
    final uri = Uri.parse('${ApiConfig.apiRoot}/auth/login');
    final body = jsonEncode({
      if (schoolCode != null && schoolCode.isNotEmpty) 'school_code': schoolCode,
      'identifier': identifier,
      'password': password,
    });

    http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw ApiException(
        'The server took too long to respond. Check your connection and try again.',
      );
    } on http.ClientException {
      throw ApiException(
        'Could not reach the server. Check your connection and try again.',
      );
    }

    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode >= 400) {
      throw ApiException(
        (decoded['message'] as String?) ?? 'Invalid credentials.',
        statusCode: response.statusCode,
      );
    }

    final role = decoded['role'] == 'gateway_sender'
        ? SessionRole.gatewaySender
        : SessionRole.parent;

    return UnifiedLoginResult(
      role: role,
      token: decoded['token'] as String,
      parentProfile: decoded['parent'] as Map<String, dynamic>?,
      deviceProfile: decoded['device'] as Map<String, dynamic>?,
    );
  }
}
