import 'package:flutter/material.dart';

import 'data/auth_api.dart';
import 'data/gateway_sender_repository.dart';
import 'data/parent_repository.dart';
import 'features/auth/login_screen.dart';
import 'features/dashboard/parent_shell.dart';
import 'features/gateway/gateway_sender_shell.dart';
import 'services/theme_controller.dart';

/// Decides Login vs. one of two shells purely from which repository (if
/// either) already has a stored session — swapping between them is a plain
/// setState, no named routes, since this app only ever has these
/// destinations. A device is only ever logged in as one role at a time (the
/// shared login screen resolves to exactly one), so checking parent first
/// then gateway is safe — at most one will ever say yes.
class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    required this.parentRepository,
    required this.gatewayRepository,
    required this.themeController,
  });
  final ParentRepository parentRepository;
  final GatewaySenderRepository gatewayRepository;
  final ThemeController themeController;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late Future<SessionRole?> _session;

  @override
  void initState() {
    super.initState();
    _session = _resolveSession();
  }

  Future<SessionRole?> _resolveSession() async {
    if (await widget.parentRepository.hasStoredSession()) {
      return SessionRole.parent;
    }
    if (await widget.gatewayRepository.hasStoredSession()) {
      return SessionRole.gatewaySender;
    }
    return null;
  }

  // Block bodies, not `=> _session = ...` — an arrow body's value is the
  // assignment's value (the Future itself), which setState() rejects since
  // its callback must return void.
  void _handleLoggedIn(SessionRole role) => setState(() {
    _session = Future.value(role);
  });

  void _handleLoggedOut() => setState(() {
    _session = Future.value(null);
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<SessionRole?>(
    future: _session,
    builder: (context, snapshot) {
      if (!snapshot.hasData && snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }

      return switch (snapshot.data) {
        SessionRole.parent => ParentShell(
          repository: widget.parentRepository,
          onLoggedOut: _handleLoggedOut,
          themeController: widget.themeController,
        ),
        SessionRole.gatewaySender => GatewaySenderShell(
          repository: widget.gatewayRepository,
          onLoggedOut: _handleLoggedOut,
          themeController: widget.themeController,
        ),
        null => LoginScreen(
          parentRepository: widget.parentRepository,
          gatewayRepository: widget.gatewayRepository,
          onLoggedIn: _handleLoggedIn,
        ),
      };
    },
  );
}
