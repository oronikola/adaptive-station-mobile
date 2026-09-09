import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sim_data_new/sim_data.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/api_client.dart';
import '../../data/gateway_sender_repository.dart';
import '../../design/components.dart';
import '../../design/station_theme.dart';
import '../../services/sim_sms_sender.dart';
import '../../services/theme_controller.dart';

enum _SendStatus { sending, sent, delivered, notDelivered, failed }

/// One claimed message's outcome, shown as a row in the recipient list —
/// this is the structured replacement for what used to be a scrolling raw
/// text log, so an operator can see at a glance which numbers actually got
/// the message rather than just a stream of lines.
class _SendRecord {
  _SendRecord({
    required this.id,
    required this.phoneNumber,
    required this.message,
    required this.status,
    required this.timestamp,
  });
  final String id;
  final String phoneNumber;
  final String message;
  _SendStatus status;
  DateTime timestamp;
  String? error;
}

/// Gateway-sender mode's whole screen: claims a batch from the shared
/// sms_outbox pool, sends each message via whichever SIM's turn it is, and
/// reports status back immediately per message (not batched at the end —
/// that's what makes the backend's reclaim lease and live fleet stats
/// meaningful), then keeps listening for the carrier's delivery report on
/// each one. See IP-007 (adaptive-station) for the server-side design and
/// the device-app contract this implements.
///
/// Deliberately much simpler than the standalone dual_sim_sms_Android14 app
/// it replaces: no per-school selection (the whole point of the global
/// pool), no local daily-limit bookkeeping (the backend already tracks
/// sent/failed-today per device) — just claim, send, report, repeat.
class GatewaySenderShell extends StatefulWidget {
  const GatewaySenderShell({
    super.key,
    required this.repository,
    required this.onLoggedOut,
    required this.themeController,
  });
  final GatewaySenderRepository repository;
  final VoidCallback onLoggedOut;
  final ThemeController themeController;

  @override
  State<GatewaySenderShell> createState() => _GatewaySenderShellState();
}

class _GatewaySenderShellState extends State<GatewaySenderShell> {
  static const _pollInterval = Duration(seconds: 15);
  static const _perSimSendDelay = Duration(seconds: 10);
  static const _batchSize = 20;
  static const _maxRecords = 200;

  List<SimCard> _simCards = [];
  final List<_SendRecord> _records = [];
  StreamSubscription<SmsDeliveryReport>? _deliverySubscription;
  bool _running = false;
  bool _permissionsGranted = false;
  int _nextSimIndex = 0;
  int _sentCount = 0;
  int _deliveredCount = 0;
  int _failedCount = 0;

  @override
  void initState() {
    super.initState();
    _deliverySubscription = SimSmsSender.deliveryReports.listen(_onDeliveryReport);
    _bootstrap();
  }

  @override
  void dispose() {
    _running = false;
    _deliverySubscription?.cancel();
    unawaited(WakelockPlus.disable());
    unawaited(FlutterForegroundTask.stopService());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final smsStatus = await Permission.sms.request();
    final phoneStatus = await Permission.phone.request();
    final granted = smsStatus.isGranted && phoneStatus.isGranted;

    List<SimCard> cards = [];
    if (granted) {
      try {
        final simData = await SimDataPlugin.getSimData();
        cards = simData.cards;
      } catch (_) {
        // Surfaced below via the "No SIM cards detected" card instead of a
        // record row — this isn't tied to any one message.
      }
    }

    if (!mounted) return;
    setState(() {
      _permissionsGranted = granted;
      _simCards = cards;
    });

    if (granted && cards.isNotEmpty) {
      _start();
    }
  }

  void _onDeliveryReport(SmsDeliveryReport report) {
    final record = _records.cast<_SendRecord?>().firstWhere(
      (r) => r?.id == report.messageId,
      orElse: () => null,
    );

    // A report for a message this session never sent (app was restarted
    // between send and the carrier's report) — nothing to reconcile locally.
    if (record == null || record.status != _SendStatus.sent) return;

    if (report.delivered) {
      record.status = _SendStatus.delivered;
      record.timestamp = DateTime.now();
      _deliveredCount++;
      // Not every carrier sends a delivery report at all — reportDelivered
      // is best-effort; a failure here shouldn't roll back the local status.
      widget.repository.reportDelivered(report.messageId).catchError((_) {});
    } else {
      record.status = _SendStatus.notDelivered;
      record.timestamp = DateTime.now();
    }

    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_running) return;
    _running = true;

    await WakelockPlus.enable();
    await FlutterForegroundTask.startService(
      notificationTitle: 'Adaptive Station — SMS Gateway',
      notificationText: 'Claiming and sending pending tap alerts.',
    );

    unawaited(_loop());
  }

  Future<void> _stop() async {
    _running = false;
    await WakelockPlus.disable();
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() {});
  }

  Future<void> _loop() async {
    while (_running) {
      try {
        final messages = await widget.repository.claim(
          batchSize: _batchSize,
        );

        if (messages.isEmpty) {
          await Future.delayed(_pollInterval);
          continue;
        }

        for (final message in messages) {
          if (!_running) break;

          final record = _SendRecord(
            id: message.id,
            phoneNumber: message.phoneNumber,
            message: message.message,
            status: _SendStatus.sending,
            timestamp: DateTime.now(),
          );
          _records.insert(0, record);
          if (_records.length > _maxRecords) _records.removeLast();
          if (mounted) setState(() {});

          final sim = _simCards[_nextSimIndex % _simCards.length];
          _nextSimIndex++;

          final result = await SimSmsSender.send(
            subscriptionId: sim.subscriptionId,
            phoneNumber: message.phoneNumber,
            message: message.message,
            messageId: message.id,
          );

          if (result == 'sent') {
            await widget.repository.reportSent(message.id);
            record.status = _SendStatus.sent;
            _sentCount++;
          } else {
            final error = result.replaceFirst('error: ', '');
            await widget.repository.reportFailed(message.id, error);
            record.status = _SendStatus.failed;
            record.error = error;
            _failedCount++;
          }
          record.timestamp = DateTime.now();

          if (mounted) setState(() {});

          // Carrier spam-detection throttle, not an Android limitation —
          // see IP-007's device-app contract for why this should eventually
          // become server-configurable rather than a fixed constant.
          await Future.delayed(_perSimSendDelay);
        }
      } catch (_) {
        await Future.delayed(_pollInterval);
      }
    }
  }

  Future<void> _logout() async {
    await _stop();
    await widget.repository.logout();
    widget.onLoggedOut();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(palette),
              const SizedBox(height: 20),
              if (!_permissionsGranted)
                _buildPermissionsCard(palette)
              else if (_simCards.isEmpty)
                const StationCard(child: Text('No SIM cards detected. Insert at least one SIM.'))
              else ...[
                _buildStatsRow(palette),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _running ? _stop : _start,
                    child: Text(_running ? 'Pause sending' : 'Resume sending'),
                  ),
                ),
                const SizedBox(height: 20),
                SectionHeading(title: 'Recipients (${_records.length})'),
                Expanded(child: _buildRecipientList(palette)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(StationPalette palette) => Row(
    children: [
      StationAvatar(initials: 'AS', color: Colors.white, background: palette.blue),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.repository.deviceLabel ?? 'Gateway device',
              style: Theme.of(context).textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'SMS GATEWAY · ${ApiConfig.apiRoot} · ${_simCards.length} SIM(s)',
              style: StationFonts.mono(fontSize: 10.5, color: palette.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      ThemeToggleButton(themeController: widget.themeController),
      IconButton(
        tooltip: 'Log out',
        onPressed: _logout,
        icon: const Icon(Icons.logout),
      ),
    ],
  );

  Widget _buildPermissionsCard(StationPalette palette) => StationCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SMS and phone permissions are required.',
          style: TextStyle(color: palette.heading, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _bootstrap, child: const Text('Grant permissions')),
      ],
    ),
  );

  Widget _buildStatsRow(StationPalette palette) => Row(
    children: [
      Expanded(child: _StatCard(label: 'Sent', value: _sentCount, color: palette.blue)),
      const SizedBox(width: 10),
      Expanded(child: _StatCard(label: 'Delivered', value: _deliveredCount, color: palette.green)),
      const SizedBox(width: 10),
      Expanded(child: _StatCard(label: 'Failed', value: _failedCount, color: Colors.red)),
    ],
  );

  Widget _buildRecipientList(StationPalette palette) {
    if (_records.isEmpty) {
      return StationCard(
        child: Center(
          child: Text('Nothing sent yet.', style: TextStyle(color: palette.muted)),
        ),
      );
    }

    return StationCard(
      padding: EdgeInsets.zero,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _records.length,
        separatorBuilder: (context, index) => Divider(height: 1, color: palette.border),
        itemBuilder: (context, index) => _RecipientRow(record: _records[index]),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return StationCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: palette.muted, fontSize: 11)),
          const SizedBox(height: 2),
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _RecipientRow extends StatelessWidget {
  const _RecipientRow({required this.record});
  final _SendRecord record;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.phoneNumber,
                  style: StationFonts.mono(fontSize: 13, color: palette.heading, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  record.error ?? record.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _statusPill(palette),
              const SizedBox(height: 4),
              Text(
                _formatTime(record.timestamp),
                style: StationFonts.mono(fontSize: 10, color: palette.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusPill(StationPalette palette) {
    final (label, color, bg) = switch (record.status) {
      _SendStatus.sending => ('Sending', palette.muted, palette.inset),
      _SendStatus.sent => ('Sent', palette.blue, palette.blueTint),
      _SendStatus.delivered => ('Delivered', palette.green, palette.greenTint),
      _SendStatus.notDelivered => ('Not confirmed', palette.muted, palette.inset),
      _SendStatus.failed => ('Failed', Colors.red, Colors.red.withValues(alpha: 0.12)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(30)),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
