import 'package:flutter/material.dart';

import '../../data/gateway_sender_repository.dart';
import '../../design/components.dart';
import '../../design/station_theme.dart';

/// Shown when a gateway-sender account is logged into a `parent`-flavor
/// build (see app_root.dart's docblock) — that build's manifest has
/// SEND_SMS and friends stripped out, so the normal GatewaySenderShell would
/// otherwise render but never actually be able to send anything, with no
/// obvious explanation why. Signs the device out immediately so it can't be
/// left sitting on a screen that looks like it's working.
class WrongFlavorScreen extends StatefulWidget {
  const WrongFlavorScreen({
    super.key,
    required this.gatewayRepository,
    required this.onLoggedOut,
  });
  final GatewaySenderRepository gatewayRepository;
  final VoidCallback onLoggedOut;

  @override
  State<WrongFlavorScreen> createState() => _WrongFlavorScreenState();
}

class _WrongFlavorScreenState extends State<WrongFlavorScreen> {
  bool _signingOut = false;

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    await widget.gatewayRepository.logout();
    widget.onLoggedOut();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    final error = Theme.of(context).colorScheme.error;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // A real top bar — the brand mark lives here, not floating in
            // the middle of an otherwise-empty screen.
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Align(alignment: Alignment.centerLeft, child: StationBrand()),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: palette.border),
                        boxShadow: palette.cardShadow,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: error.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(Icons.sms_failed_rounded, size: 26, color: error),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'This device can\'t send SMS',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'This account is a gateway-sender device, but this copy of '
                            'the app is the parent build, which doesn\'t include SMS/'
                            'phone permissions.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Install the gateway build on this phone instead, or log '
                            'in with a parent account here.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _signingOut ? null : _signOut,
                  child: _signingOut
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Log out'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
