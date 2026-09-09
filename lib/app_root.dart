import 'package:flutter/material.dart';

import 'data/parent_repository.dart';
import 'features/auth/login_screen.dart';
import 'features/dashboard/parent_shell.dart';
import 'services/theme_controller.dart';

/// Decides Login vs. Shell purely from whether a token is already in secure
/// storage — swapping between them is a plain setState, no named routes,
/// since this app only ever has these two top-level destinations.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key, required this.repository, required this.themeController});
  final ParentRepository repository;
  final ThemeController themeController;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late Future<bool> _hasSession;

  @override
  void initState() {
    super.initState();
    _hasSession = widget.repository.hasStoredSession();
  }

  // Block bodies, not `=> _hasSession = ...` — an arrow body's value is the
  // assignment's value (the Future itself), which setState() rejects since
  // its callback must return void.
  void _handleLoggedIn() => setState(() {
    _hasSession = Future.value(true);
  });

  void _handleLoggedOut() => setState(() {
    _hasSession = Future.value(false);
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _hasSession,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }

      return snapshot.data!
          ? ParentShell(
              repository: widget.repository,
              onLoggedOut: _handleLoggedOut,
              themeController: widget.themeController,
            )
          : LoginScreen(
              repository: widget.repository,
              onLoggedIn: _handleLoggedIn,
            );
    },
  );
}
