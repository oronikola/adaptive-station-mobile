import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sim_data_new/sim_data.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/api_client.dart';
import '../../data/gateway_sender_repository.dart';
import '../../design/components.dart';
import '../../design/station_theme.dart';
import '../../services/gateway_realtime_service.dart';
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
    required this.simLabel,
  });
  final String id;
  final String phoneNumber;
  final String message;
  _SendStatus status;
  DateTime timestamp;
  String? error;
  final String simLabel;
}

/// Gateway-sender mode's whole screen: runs one independent claim/send/report
/// loop PER SIM CARD (not one shared loop round-robining between them), and
/// keeps listening for the carrier's delivery report on every sent message.
/// See IP-007 (adaptive-station) for the server-side design and the
/// device-app contract this implements.
///
/// Why per-SIM, not one shared loop: the 10s delay between sends exists to
/// stay under a carrier's per-number spam-detection threshold — a budget
/// the carrier tracks per phone number, not per phone. Two SIMs are two
/// distinct numbers with two independent budgets, so serializing them behind
/// one shared delay (the original design) wasted the second SIM entirely: a
/// dual-SIM phone sent no faster than a single-SIM one. Running one loop per
/// SIM lets both send concurrently, each governed only by its own delay —
/// roughly doubling a phone's real throughput with hardware already sitting
/// idle. This is safe on typical DSDS (dual-SIM-dual-standby) hardware:
/// sending an SMS is a brief signaling-plane transaction, not a sustained
/// call/data session, and Android's telephony stack already queues/
/// interleaves short per-SIM radio transactions transparently — the same
/// thing that lets a phone receive a text on one SIM while sending on the
/// other during ordinary dual-SIM use.
///
/// `claimBatch()` on the backend was already built for many independent,
/// concurrent callers (SKIP LOCKED) — every phone in a 20+ device fleet
/// already claims from the same shared pool this way, so treating a second
/// SIM as one more independent worker needs no backend change at all.
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
  int _sentCount = 0;
  int _deliveredCount = 0;
  int _failedCount = 0;

  // Lets an idle _loopForSim() skip the rest of its poll wait the instant
  // the server broadcasts "a message was just queued" (see
  // GatewayRealtimeService/App\Events\SmsGatewayWakeUp) instead of always
  // waiting out the full interval. Purely a latency shortcut: the actual
  // claim still goes through the same HTTP call either way, so a missed or
  // stale wake-up event is harmless — the poll loop is still the fallback.
  final _wakeEvents = StreamController<void>.broadcast();
  GatewayRealtimeService? _realtime;

  @override
  void initState() {
    super.initState();
    _deliverySubscription = SimSmsSender.deliveryReports.listen(_onDeliveryReport);
    _realtime = GatewayRealtimeService(
      host: ApiConfig.realtimeHost,
      port: ApiConfig.realtimePort,
      appKey: ApiConfig.realtimeAppKey,
    )..connect(() => _wakeEvents.add(null));
    _bootstrap();
  }

  @override
  void dispose() {
    _running = false;
    _deliverySubscription?.cancel();
    _realtime?.disconnect();
    unawaited(_wakeEvents.close());
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
    if (mounted) setState(() {});

    await WakelockPlus.enable();
    await FlutterForegroundTask.startService(
      notificationTitle: 'Adaptive Station — SMS Gateway',
      notificationText: 'Claiming and sending pending tap alerts.',
    );

    // One independent loop per SIM — see the class docblock for why this is
    // both safe and the actual fix for a dual-SIM phone's real throughput.
    for (final sim in _simCards) {
      unawaited(_loopForSim(sim));
    }
  }

  Future<void> _stop() async {
    _running = false;
    await WakelockPlus.disable();
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() {});
  }

  // Guards against every SIM's loop hitting the same 401 at once (they all
  // poll independently) and each trying to log out / show the snackbar.
  bool _handlingUnauthorized = false;

  /// GatewayApiClient already clears the stored token and throws this for a
  /// 401 — previously that was swallowed by _loopForSim's catch-all, so a
  /// revoked/expired device credential left the screen silently retrying
  /// forever, still showing "LIVE", with no way for whoever's holding the
  /// phone to know it needed a fresh login.
  Future<void> _handleUnauthorized() async {
    if (_handlingUnauthorized) return;
    _handlingUnauthorized = true;

    await _stop();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session expired. Please log in again.')),
      );
    }
    widget.onLoggedOut();
  }

  /// Waits for whichever comes first: the normal poll interval, or the next
  /// server wake-up broadcast. A stream error (e.g. the controller closing
  /// mid-wait, during dispose) is left to propagate to _loopForSim's own
  /// try/catch rather than handled here — that catch already exists for
  /// exactly this kind of "something interrupted the wait" case.
  Future<void> _waitForWakeUpOrPollInterval() {
    return Future.any([
      Future.delayed(_pollInterval),
      _wakeEvents.stream.first,
    ]);
  }

  Future<void> _loopForSim(SimCard sim) async {
    final simLabel = 'SIM ${sim.slotIndex + 1}';

    while (_running) {
      try {
        final messages = await widget.repository.claim(
          batchSize: _batchSize,
        );

        if (messages.isEmpty) {
          await _waitForWakeUpOrPollInterval();
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
            simLabel: simLabel,
          );
          _records.insert(0, record);
          if (_records.length > _maxRecords) _records.removeLast();
          if (mounted) setState(() {});

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

          // Carrier spam-detection throttle, not an Android limitation — a
          // budget the carrier tracks per SIM/number, so each SIM's loop
          // waits out its own delay independently of the other SIM's. See
          // IP-007's device-app contract for why this should eventually
          // become server-configurable rather than a fixed constant.
          await Future.delayed(_perSimSendDelay);
        }
      } on ApiException catch (e) {
        if (e.statusCode == 401) {
          await _handleUnauthorized();
          return;
        }
        await Future.delayed(_pollInterval);
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(palette),
              const SizedBox(height: 22),
              if (!_permissionsGranted)
                _buildEmptyState(
                  palette,
                  icon: LucideIcons.smartphone,
                  title: 'Permissions needed',
                  message: 'SMS and phone access are required to operate as a gateway device.',
                  action: FilledButton(onPressed: _bootstrap, child: const Text('Grant permissions')),
                )
              else if (_simCards.isEmpty)
                _buildEmptyState(
                  palette,
                  icon: LucideIcons.wifiOff,
                  title: 'No SIM detected',
                  message: 'Insert at least one SIM card to start sending.',
                )
              else ...[
                _buildStatsRow(palette),
                const SizedBox(height: 14),
                _buildRunControl(palette),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text('Recipients', style: Theme.of(context).textTheme.titleMedium),
                    ),
                    Text(
                      '${_records.length}',
                      style: StationFonts.mono(fontSize: 12, color: palette.muted, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
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
      Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: palette.blueTint, borderRadius: BorderRadius.circular(15)),
        child: Icon(LucideIcons.radio, size: 22, color: palette.blue),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    widget.repository.deviceLabel ?? 'Gateway device',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (_permissionsGranted && _simCards.isNotEmpty) _buildLiveBadge(palette),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${ApiConfig.apiRoot} · ${_simCards.length} SIM(s)',
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
        icon: Icon(LucideIcons.logOut, size: 20),
      ),
    ],
  );

  Widget _buildLiveBadge(StationPalette palette) {
    final accent = _running ? palette.green : palette.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _running ? palette.greenTint : palette.inset,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_running) ...[
            RadarPulse(color: accent, size: 6, ringCount: 1),
            const SizedBox(width: 5),
          ] else ...[
            Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: accent)),
            const SizedBox(width: 5),
          ],
          Text(
            _running ? 'LIVE' : 'PAUSED',
            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: accent, letterSpacing: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    StationPalette palette, {
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) => Expanded(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: palette.inset, borderRadius: BorderRadius.circular(20)),
              child: Icon(icon, size: 28, color: palette.muted),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: palette.muted, height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 18), action],
          ],
        ),
      ),
    ),
  );

  Widget _buildStatsRow(StationPalette palette) => Row(
    children: [
      Expanded(child: _StatCard(icon: LucideIcons.send, label: 'Sent', value: _sentCount, color: palette.blue, tint: palette.blueTint)),
      const SizedBox(width: 10),
      Expanded(child: _StatCard(icon: LucideIcons.checkCheck, label: 'Delivered', value: _deliveredCount, color: palette.green, tint: palette.greenTint)),
      const SizedBox(width: 10),
      Expanded(child: _StatCard(icon: LucideIcons.xCircle, label: 'Failed', value: _failedCount, color: Colors.red, tint: Colors.red.withValues(alpha: 0.12))),
    ],
  );

  Widget _buildRunControl(StationPalette palette) => StationCard(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      children: [
        Icon(
          _running ? LucideIcons.activity : LucideIcons.pause,
          size: 18,
          color: _running ? palette.green : palette.muted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _running ? 'Actively claiming and sending' : 'Sending paused',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.ink),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _running ? _stop : _start,
          icon: Icon(_running ? LucideIcons.pause : LucideIcons.play, size: 15),
          label: Text(_running ? 'Pause' : 'Resume'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 38),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );

  Widget _buildRecipientList(StationPalette palette) {
    if (_records.isEmpty) {
      return _buildEmptyState(
        palette,
        icon: LucideIcons.messageSquare,
        title: 'Nothing sent yet',
        message: 'Claimed messages will appear here as soon as there\'s a pending tap alert.',
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
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.tint,
  });
  final IconData icon;
  final String label;
  final int value;
  final Color color;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return StationCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(height: 10),
          TweenAnimationBuilder<int>(
            tween: IntTween(begin: 0, end: value),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, _) => Text(
              '$animatedValue',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Text(label, style: TextStyle(color: palette.muted, fontSize: 11)),
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
    final (icon, color, bg) = _statusVisuals(palette);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      record.phoneNumber,
                      style: StationFonts.mono(fontSize: 13, color: palette.heading, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '· ${record.simLabel}',
                      style: StationFonts.mono(fontSize: 10.5, color: palette.muted),
                    ),
                  ],
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
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _statusPill(context, key: ValueKey(record.status)),
              ),
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

  (IconData, Color, Color) _statusVisuals(StationPalette palette) => switch (record.status) {
    _SendStatus.sending => (LucideIcons.clock3, palette.muted, palette.inset),
    _SendStatus.sent => (LucideIcons.send, palette.blue, palette.blueTint),
    _SendStatus.delivered => (LucideIcons.checkCheck, palette.green, palette.greenTint),
    _SendStatus.notDelivered => (LucideIcons.helpCircle, palette.muted, palette.inset),
    _SendStatus.failed => (LucideIcons.xCircle, Colors.red, Colors.red.withValues(alpha: 0.12)),
  };

  Widget _statusPill(BuildContext context, {required Key key}) {
    final palette = StationPalette.of(context);
    final (label, color, bg) = switch (record.status) {
      _SendStatus.sending => ('Sending', palette.muted, palette.inset),
      _SendStatus.sent => ('Sent', palette.blue, palette.blueTint),
      _SendStatus.delivered => ('Delivered', palette.green, palette.greenTint),
      _SendStatus.notDelivered => ('Not confirmed', palette.muted, palette.inset),
      _SendStatus.failed => ('Failed', Colors.red, Colors.red.withValues(alpha: 0.12)),
    };

    return Container(
      key: key,
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
