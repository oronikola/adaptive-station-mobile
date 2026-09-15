import 'package:flutter/material.dart';

import 'data/auth_api.dart';
import 'data/gateway_sender_repository.dart';
import 'data/parent_repository.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/wrong_flavor_screen.dart';
import 'features/dashboard/parent_shell.dart';
import 'features/gateway/gateway_sender_shell.dart';
import 'services/app_flavor.dart';
import 'services/theme_controller.dart';

class _ResolvedSession {
  const _ResolvedSession(this.role, this.flavor);
  final SessionRole? role;
  final AppFlavor flavor;
}

/// Decides Login vs. one of two shells purely from which repository (if
/// either) already has a stored session — swapping between them is a plain
/// setState, no named routes, since this app only ever has these
/// destinations. A device is only ever logged in as one role at a time (the
/// shared login screen resolves to exactly one), so checking parent first
/// then gateway is safe — at most one will ever say yes.
///
/// Login itself never checks flavor (both shells' Dart code is compiled
/// into every flavor, and the server resolves role purely from the
/// identifier). What flavor DOES gate is whether a gateway-sender session
/// is actually usable: the `parent` flavor has SEND_SMS and friends
/// stripped from its manifest (see android/app/src/parent/AndroidManifest.xml),
/// so a gateway account logging into that build would land on a
/// GatewaySenderShell that can silently never send anything. We catch that
/// combination here and show an explicit explanation instead.
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
  late Future<_ResolvedSession> _session;

  @override
  void initState() {
    super.initState();
    _session = _resolveSession();
  }

  Future<_ResolvedSession> _resolveSession() async {
    final results = await Future.wait([
      _resolveRole(),
      AppFlavorService.resolve(),
    ]);
    return _ResolvedSession(
      results[0] as SessionRole?,
      results[1] as AppFlavor,
    );
  }

  Future<SessionRole?> _resolveRole() async {
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
    _session = _session.then((prev) => _ResolvedSession(role, prev.flavor));
  });

  void _handleLoggedOut() => setState(() {
    _session = _session.then((prev) => _ResolvedSession(null, prev.flavor));
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<_ResolvedSession>(
    future: _session,
    builder: (context, snapshot) {
      final resolved = snapshot.data;
      if (resolved == null && snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }

      if (resolved!.role == SessionRole.gatewaySender &&
          resolved.flavor == AppFlavor.parent) {
        return WrongFlavorScreen(
          gatewayRepository: widget.gatewayRepository,
          onLoggedOut: _handleLoggedOut,
        );
      }

      return switch (resolved.role) {
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
