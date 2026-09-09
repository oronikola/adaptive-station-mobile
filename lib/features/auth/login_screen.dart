import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/auth_api.dart';
import '../../data/gateway_sender_repository.dart';
import '../../data/parent_repository.dart';
import '../../design/components.dart';
import '../../services/push_notification_service.dart';

/// Shared by both account types — a parent (login ID + password) and a
/// gateway-sender device (username + password). Which one a login resolves
/// to is decided server-side purely from which identifier space the value
/// matches (see AuthApi's docblock); this screen never asks the person to
/// pick a role, or a school, up front.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.parentRepository,
    required this.gatewayRepository,
    required this.onLoggedIn,
  });
  final ParentRepository parentRepository;
  final GatewaySenderRepository gatewayRepository;
  final ValueChanged<SessionRole> onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authApi = AuthApi();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final result = await _authApi.login(
        identifier: _identifierController.text.trim(),
        password: _passwordController.text,
      );

      if (result.role == SessionRole.parent) {
        await widget.parentRepository.saveSession(
          result.token,
          result.parentProfile,
        );

        // Push registration is parent-only, and best-effort — a parent
        // should still be able to use the app if this single call fails.
        PushNotificationService.attachRepository(widget.parentRepository);
        final token = PushNotificationService.lastKnownToken;
        if (token != null) {
          widget.parentRepository.registerDeviceToken(token).catchError((_) {});
        }
      } else {
        await widget.gatewayRepository.saveSession(
          result.token,
          result.deviceProfile,
        );
      }

      if (!mounted) return;
      widget.onLoggedIn(result.role);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(
        () => _error =
            'Could not reach the server. Check your connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: StationBrand()),
                  const SizedBox(height: 32),
                  Text(
                    'Welcome back',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Parents: log in with your Parent ID and password.\n'
                    'Gateway devices: use your device username.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _identifierController,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Parent ID or device username',
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? 'Enter your Parent ID or username'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Enter your password'
                        : null,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        : const Text('Log in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
