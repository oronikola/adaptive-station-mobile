import 'dart:async';

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/parent_repository.dart';
import '../../design/components.dart';
import '../../design/skeleton.dart';
import '../../design/station_theme.dart';
import '../../design/tap_alert_banner.dart';
import '../../services/push_notification_service.dart';
import '../../services/realtime_service.dart';
import '../../services/theme_controller.dart';
import 'dashboard_screen.dart';

/// One row in the grouped attendance list — either a day-section label or a
/// tap. Modeled as a sealed type so [SliverChildBuilderDelegate] can render
/// either lazily, one row at a time, from a single flat list.
sealed class _AttendanceRow {}

class _DayHeaderRow extends _AttendanceRow {
  _DayHeaderRow(this.label);
  final String label;
}

class _TapRowItem extends _AttendanceRow {
  _TapRowItem(this.tap);
  final AttendanceTap tap;
}

/// Buckets [taps] (already newest-first) into "Today" / "Yesterday" / date
/// groups, inserting one header per group as the day changes.
List<_AttendanceRow> _groupTapsByDay(List<AttendanceTap> taps) {
  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);

  String labelFor(DateTime occurredAt) {
    final day = DateTime(occurredAt.year, occurredAt.month, occurredAt.day);
    final diff = todayDate.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return formatTapDate(occurredAt);
  }

  final rows = <_AttendanceRow>[];
  String? currentLabel;
  for (final tap in taps) {
    final label = labelFor(tap.occurredAt);
    if (label != currentLabel) {
      rows.add(_DayHeaderRow(label));
      currentLabel = label;
    }
    rows.add(_TapRowItem(tap));
  }
  return rows;
}

class ParentShell extends StatefulWidget {
  const ParentShell({
    super.key,
    required this.repository,
    required this.onLoggedOut,
    required this.themeController,
  });
  final ParentRepository repository;
  final VoidCallback onLoggedOut;
  final ThemeController themeController;

  @override
  State<ParentShell> createState() => _ParentShellState();
}

class _ParentShellState extends State<ParentShell> {
  int _destination = 0;
  String? _studentId;
  bool _loading = true;
  String? _error;
  List<Student> _children = const [];
  List<AttendanceTap> _taps = const [];
  NotificationPreferences _preferences = const NotificationPreferences(
    notifyIn: true,
    notifyOut: true,
  );
  RealtimeService? _realtime;
  int _unreadUpdates = 0;
  static const _labels = ['Home', 'Attendance', 'Updates', 'Account'];
  static const _destinations = [
    StationNavDestination(icon: LucideIcons.home, label: 'Home'),
    StationNavDestination(icon: LucideIcons.calendar, label: 'Attendance'),
    StationNavDestination(icon: LucideIcons.bell, label: 'Updates'),
    StationNavDestination(icon: LucideIcons.user, label: 'Account'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _realtime?.disconnect();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final children = await widget.repository.fetchChildren();
      final tapLists = await Future.wait(
        children.map(widget.repository.fetchAttendance),
      );
      final taps = tapLists.expand((list) => list).toList()
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
      final preferences = await widget.repository
          .fetchNotificationPreferences();

      if (!mounted) return;
      setState(() {
        _children = children;
        _taps = taps;
        _preferences = preferences;
        _loading = false;
      });
      _connectRealtime();
    } on ApiException catch (e) {
      if (!mounted) return;
      // A 401 here means the token is missing/expired/revoked (ApiClient
      // already cleared it from storage) — showing a "try again" error
      // would just fail forever, so send the parent back to login instead.
      if (e.statusCode == 401) {
        _realtime?.disconnect();
        _realtime = null;
        widget.onLoggedOut();
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your family\'s attendance right now.';
        _loading = false;
      });
    }
  }

  /// Catches [_children] up after a live tap arrives for a student not yet
  /// in the locally-loaded list (newly linked since the dashboard's last
  /// load) — deliberately doesn't touch `_loading`/`_error`, so it can't
  /// interrupt whatever the user is currently looking at.
  Future<void> _refreshChildrenQuietly() async {
    try {
      final children = await widget.repository.fetchChildren();
      if (!mounted) return;
      setState(() => _children = children);
    } catch (_) {
      // Best-effort — the next pull-to-refresh or app restart catches up regardless.
    }
  }

  /// One WebSocket connection for the whole session (not re-opened on every
  /// pull-to-refresh) — a live tap.recorded push is merged straight into
  /// [_taps] rather than triggering a full re-fetch.
  void _connectRealtime() {
    final parentId = widget.repository.parentId;
    debugPrint('ParentShell: connecting realtime for parentId=$parentId');
    if (parentId == null || _realtime != null) return;

    _realtime = RealtimeService(
      host: ApiConfig.realtimeHost,
      port: ApiConfig.realtimePort,
      appKey: ApiConfig.realtimeAppKey,
      scheme: ApiConfig.realtimeScheme,
      repository: widget.repository,
    )..connect(parentId, _handleLiveTap);
  }

  void _handleLiveTap(Map<String, dynamic> payload) {
    if (!mounted) return;

    final studentId = payload['person_id'] as String?;
    Student? student;
    for (final candidate in _children) {
      if (candidate.id == studentId) {
        student = candidate;
        break;
      }
    }

    if (student == null) {
      if (studentId == null) return;
      // A student linked to this parent after the dashboard's last load
      // (e.g. the school just approved a new child) — the broadcast still
      // carries their name, so this can show something useful right away
      // instead of silently dropping the tap; _load() catches _children up
      // properly in the background.
      final name = (payload['student_name'] as String?) ?? 'Your child';
      student = Student(studentId, name, '', '', '');
      unawaited(_refreshChildrenQuietly());
    }

    final tap = AttendanceTap.fromJson(payload, student);
    setState(() {
      _taps = [tap, ..._taps.where((existing) => existing.id != tap.id)]
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
      // Already looking at Updates when this arrives? Nothing "unread" about
      // it — only count alerts the parent hasn't actually seen yet.
      if (_destination != 2) _unreadUpdates++;
    });

    // A push notification only reaches the device tray — it never appears
    // while the app itself is open and in the foreground. This top banner
    // is what the user actually sees on-screen for a live tap in that case.
    TapAlertBanner.show(
      context,
      tap: tap,
      onTap: () => _navigate(1, studentId: tap.student.id),
    );
  }

  void _logout() {
    _realtime?.disconnect();
    _realtime = null;
    PushNotificationService.detachRepository();
    // Navigate away immediately rather than awaiting the network round-trip
    // to revoke the token server-side — that revocation still happens (see
    // ApiParentRepository.logout(), which clears the local token either
    // way), but a slow/unreachable server should never make the logout
    // button look like it did nothing.
    unawaited(widget.repository.logout());
    widget.onLoggedOut();
  }

  Future<void> _updatePreference({bool? notifyIn, bool? notifyOut}) async {
    HapticFeedback.lightImpact();
    final previous = _preferences;
    final updated = _preferences.copyWith(
      notifyIn: notifyIn,
      notifyOut: notifyOut,
    );
    setState(() => _preferences = updated);
    try {
      await widget.repository.updateNotificationPreferences(updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401) {
        _realtime?.disconnect();
        _realtime = null;
        widget.onLoggedOut();
        return;
      }
      setState(() => _preferences = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save that preference. Please try again.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _preferences = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save that preference. Please try again.'),
        ),
      );
    }
  }

  void _navigate(int index, {String? studentId}) {
    if (index != _destination) HapticFeedback.lightImpact();
    setState(() {
      _destination = index;
      _studentId = studentId;
      if (index == 2) _unreadUpdates = 0;
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tablet = constraints.maxWidth >= 760;
      final palette = StationPalette.of(context);
      return Scaffold(
        extendBody: true,
        // Scaffold.bottomNavigationBar always wraps its child in an opaque
        // Material surface — no amount of transparent decoration on the bar
        // itself escapes that backing, which is what made the floating glass
        // bar sit on a solid white/black block. Placing it in a Stack over
        // the body instead is the only way to get a truly transparent,
        // floating overlay.
        body: Stack(
          children: [
            SafeArea(
              child: Row(
                children: [
                  if (tablet)
                    Container(
                      width: 232,
                      decoration: BoxDecoration(
                        color: palette.surface,
                        border: Border(
                          right: BorderSide(color: palette.border),
                        ),
                      ),
                      child: Column(
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: StationBrand(),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 24,
                              ),
                              children: [
                                for (var i = 0; i < _labels.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: ListTile(
                                      selected: _destination == i,
                                      selectedTileColor: palette.inset,
                                      selectedColor: palette.heading,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      leading: Badge(
                                        isLabelVisible:
                                            i == 2 && _unreadUpdates > 0,
                                        label: Text(
                                          _unreadUpdates > 9
                                              ? '9+'
                                              : '$_unreadUpdates',
                                        ),
                                        backgroundColor: palette.blue,
                                        textColor: palette.onAccent,
                                        child: Icon(
                                          _destinations[i].icon,
                                          size: 21,
                                          color: _destination == i
                                              ? palette.heading
                                              : palette.muted,
                                        ),
                                      ),
                                      title: Text(
                                        _labels[i],
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      onTap: () => _navigate(i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                StationAvatar(initials: _parentInitials()),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.repository.parentName ??
                                            'Parent account',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        'Parent account',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: palette.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: tablet ? 32 : 20,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: palette.surface,
                            border: Border(
                              bottom: BorderSide(color: palette.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: tablet
                                    ? Text(
                                        _labels[_destination],
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      )
                                    : const StationBrand(),
                              ),
                              ThemeToggleButton(
                                themeController: widget.themeController,
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: _body(context, tablet)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!tablet)
              Align(
                alignment: Alignment.bottomCenter,
                child: StationBottomNav(
                  selectedIndex: _destination,
                  onDestinationSelected: _navigate,
                  destinations: _destinations,
                  badgeCounts: {2: _unreadUpdates},
                ),
              ),
          ],
        ),
      );
    },
  );

  String _parentInitials() {
    final name = widget.repository.parentName;
    if (name == null || name.trim().isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.length >= 2
        ? '${parts.first[0]}${parts.last[0]}'.toUpperCase()
        : parts.first.substring(0, 1).toUpperCase();
  }

  Widget _body(BuildContext context, bool tablet) {
    // The floating pill nav bar (phone only) sits on top of the body now
    // that the Scaffold uses extendBody: true — pad scrollable content so
    // the last item never ends up permanently hidden underneath it.
    final navClearance = tablet ? 0.0 : 120.0;

    if (_loading) {
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          tablet ? 32 : 20,
          tablet ? 32 : 20,
          tablet ? 32 : 20,
          (tablet ? 32 : 20) + navClearance,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: _destination == 1
                ? const AttendanceSkeleton()
                : const DashboardSkeleton(),
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    return PageTransitionSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, primaryAnimation, secondaryAnimation) {
        return FadeThroughTransition(
          animation: primaryAnimation,
          secondaryAnimation: secondaryAnimation,
          child: child,
        );
      },
      child: KeyedSubtree(
        key: ValueKey<int>(_destination),
        child: _buildPage(_destination, tablet, navClearance),
      ),
    );
  }

  Widget _buildPage(int index, bool tablet, double navClearance) {
    switch (index) {
      case 0:
        return RefreshIndicator(
          key: const PageStorageKey('refresh-home'),
          onRefresh: _load,
          child: SingleChildScrollView(
            key: const PageStorageKey('scroll-home'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              tablet ? 32 : 20,
              tablet ? 32 : 20,
              tablet ? 32 : 20,
              (tablet ? 32 : 20) + navClearance,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: DashboardScreen(
                  children: _children,
                  recentTaps: _taps,
                  onHistory: () => _navigate(1),
                  onChild: (student) => _navigate(1, studentId: student.id),
                ),
              ),
            ),
          ),
        );
      case 1:
        return RefreshIndicator(
          key: const PageStorageKey('refresh-attendance'),
          onRefresh: _load,
          child: _attendance(tablet, navClearance),
        );
      case 2:
        return RefreshIndicator(
          key: const PageStorageKey('refresh-updates'),
          onRefresh: _load,
          child: SingleChildScrollView(
            key: const PageStorageKey('scroll-updates'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              tablet ? 32 : 20,
              tablet ? 32 : 20,
              tablet ? 32 : 20,
              (tablet ? 32 : 20) + navClearance,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: _updates(context),
              ),
            ),
          ),
        );
      case 3:
      default:
        return RefreshIndicator(
          key: const PageStorageKey('refresh-account'),
          onRefresh: _load,
          child: SingleChildScrollView(
            key: const PageStorageKey('scroll-account'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              tablet ? 32 : 20,
              tablet ? 32 : 20,
              tablet ? 32 : 20,
              (tablet ? 32 : 20) + navClearance,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: _account(context),
              ),
            ),
          ),
        );
    }
  }

  Widget _title(BuildContext context, String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );

  Widget _attendance(bool tablet, double navClearance) {
    final taps = _taps
        .where((tap) => _studentId == null || tap.student.id == _studentId)
        .toList();
    final rows = _groupTapsByDay(taps);
    final firstTapRowIndex = rows.indexWhere((row) => row is _TapRowItem);
    final side = tablet ? 32.0 : 20.0;

    Widget constrained(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: child,
      ),
    );

    return CustomScrollView(
      key: const PageStorageKey('scroll-attendance'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: constrained(
            Padding(
              padding: EdgeInsets.fromLTRB(side, side, side, 0),
              child: Builder(
                builder: (context) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _title(
                      context,
                      'Attendance',
                      'School gate activity · Philippine time (GMT+8)',
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('All children'),
                          selected: _studentId == null,
                          onSelected: (_) => setState(() => _studentId = null),
                        ),
                        for (final student in _children)
                          ChoiceChip(
                            label: Text(student.name.split(' ').first),
                            selected: _studentId == student.id,
                            onSelected: (_) =>
                                setState(() => _studentId = student.id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (rows.isEmpty)
          SliverToBoxAdapter(
            child: constrained(
              Padding(
                padding: EdgeInsets.fromLTRB(
                  side,
                  0,
                  side,
                  side + navClearance,
                ),
                child: const StationCard(
                  child: Text('No attendance recorded yet.'),
                ),
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final row = rows[index];
                final isLast = index == rows.length - 1;
                final padding = EdgeInsets.fromLTRB(
                  side,
                  row is _DayHeaderRow && index != 0 ? 18 : 0,
                  side,
                  isLast ? side + navClearance : 0,
                );
                return constrained(
                  Padding(
                    padding: padding,
                    child: switch (row) {
                      _DayHeaderRow(:final label) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          label.toUpperCase(),
                          style: StationFonts.mono(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: StationPalette.of(context).muted,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                      _TapRowItem(:final tap) => _timelineNode(
                        context: context,
                        tap: tap,
                        // The line only runs between two taps in the same
                        // day group — a header on either side breaks it, so
                        // the circuit visually resets per day.
                        hasAbove: index > 0 && rows[index - 1] is _TapRowItem,
                        hasBelow:
                            index < rows.length - 1 &&
                            rows[index + 1] is _TapRowItem,
                        isLive: index == firstTapRowIndex,
                      ),
                    },
                  ),
                );
              },
              // ListView.builder-style lazy building: each row is only
              // constructed when it scrolls into view, so a family's full
              // history can grow without the whole list being built upfront.
              childCount: rows.length,
            ),
          ),
      ],
    );
  }

  /// One node on the vertical "circuit" timeline: a glowing dot (mint for
  /// IN, cyan for OUT) connected to its neighbors by a glowing laser line,
  /// with the tap's own details in a glass card to its right. The line
  /// segments above/below only render when there's a same-day neighbor to
  /// connect to, so each day group reads as its own separate circuit.
  Widget _timelineNode({
    required BuildContext context,
    required AttendanceTap tap,
    required bool hasAbove,
    required bool hasBelow,
    required bool isLive,
  }) {
    final palette = StationPalette.of(context);
    final color = tap.isIn ? palette.green : palette.blue;
    final lineColor = color.withValues(alpha: 0.35);

    Widget line() => Container(
      width: 2,
      color: lineColor,
      margin: const EdgeInsets.symmetric(horizontal: 6),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 14,
              child: Column(
                children: [
                  Expanded(child: hasAbove ? line() : const SizedBox()),
                  isLive
                      ? RadarPulse(color: color, size: 10, ringCount: 2)
                      : Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                          ),
                        ),
                  Expanded(child: hasBelow ? line() : const SizedBox()),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: StationCard(
                padding: const EdgeInsets.all(14),
                child: TapRow(tap: tap),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _updates(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _title(
        context,
        'Family updates',
        'A summary of the tap alerts sent to your device.',
      ),
      if (_taps.isEmpty)
        const StationCard(child: Text('No tap alerts yet.'))
      else
        for (final tap in _taps.take(2))
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: StationCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TapRow(tap: tap, showDate: true),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => _navigate(1, studentId: tap.student.id),
                    child: const Text('View attendance'),
                  ),
                ],
              ),
            ),
          ),
    ],
  );

  Widget _account(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _title(
        context,
        'My account',
        'Your family connections and notification preferences.',
      ),
      StationCard(
        child: Row(
          children: [
            StationAvatar(initials: _parentInitials()),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.repository.parentName ?? 'Parent account',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    widget.repository.parentEmail ?? '',
                    style: TextStyle(
                      color: StationPalette.of(context).muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const SectionHeading(title: 'Tap notifications'),
      StationCard(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Tap IN alerts'),
              subtitle: const Text('When your child taps in at school'),
              value: _preferences.notifyIn,
              onChanged: (value) => _updatePreference(notifyIn: value),
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('Tap OUT alerts'),
              subtitle: const Text('When your child taps out at school'),
              value: _preferences.notifyOut,
              onChanged: (value) => _updatePreference(notifyOut: value),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const SectionHeading(title: 'Appearance'),
      StationCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Theme',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ThemeModeSelector(themeController: widget.themeController),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const SectionHeading(title: 'Connect a child'),
      StationCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your school will provide a private invitation to link your child. A student name or RFID number alone won’t grant access.',
            ),
            const SizedBox(height: 20),
            const TextField(
              enabled: false,
              decoration: InputDecoration(
                labelText: 'School invitation code',
                hintText: 'Available after account setup',
              ),
            ),
            const SizedBox(height: 16),
            const FilledButton(onPressed: null, child: Text('Connect child')),
            const SizedBox(height: 8),
            Text(
              'Ask your school\'s admin office to link a new child to your account.',
              style: TextStyle(
                fontSize: 11,
                color: StationPalette.of(context).muted,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Log out'),
        ),
      ),
    ],
  );
}

