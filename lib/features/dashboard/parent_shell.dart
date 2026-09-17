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
import 'credential_request_sheet.dart';

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

  // ── Attendance tab: calendar overview ──────────────────────────────────
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _calendarSelectedDate;

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
        // Only on first load — a pull-to-refresh re-running this must not
        // yank the calendar back to wherever the most recent tap is if the
        // parent has since navigated elsewhere in it.
        if (_calendarSelectedDate == null) _focusMostRecentActivity();
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

  Future<void> _showCredentialRequestSheet() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => CredentialRequestSheet(
      children: _children,
      onRequest: (student) async {
        try {
          return await widget.repository.requestStudentCredentials(student);
        } on ApiException catch (error) {
          if (error.statusCode == 401 && mounted) _logout();
          rethrow;
        }
      },
    ),
  );

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

  List<AttendanceTap> get _activeChildTaps => _taps
      .where((tap) => _studentId == null || tap.student.id == _studentId)
      .toList();

  /// Jumps the calendar to whichever month the active child's most recent
  /// tap falls in and selects that date, so opening (or switching children
  /// on) the Attendance tab shows something meaningful immediately instead
  /// of an empty "tap a date" hint. Called from setState blocks — mutates
  /// state directly rather than calling setState itself, so callers can
  /// batch it with their own other changes (e.g. switching _studentId) into
  /// a single rebuild.
  void _focusMostRecentActivity() {
    final taps = _activeChildTaps;
    if (taps.isEmpty) return;
    final mostRecent = taps.first; // _taps is kept sorted newest-first
    final date = DateTime(
      mostRecent.occurredAt.year,
      mostRecent.occurredAt.month,
      mostRecent.occurredAt.day,
    );
    _calendarMonth = DateTime(date.year, date.month);
    _calendarSelectedDate = date;
  }

  void _jumpToToday() {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    setState(() {
      _calendarMonth = DateTime(now.year, now.month);
      _calendarSelectedDate = DateTime(now.year, now.month, now.day);
    });
  }

  Widget _attendance(bool tablet, double navClearance) {
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
                          onSelected: (_) => setState(() {
                            _studentId = null;
                            _focusMostRecentActivity();
                          }),
                        ),
                        for (final student in _children)
                          ChoiceChip(
                            label: Text(student.name.split(' ').first),
                            selected: _studentId == student.id,
                            onSelected: (_) => setState(() {
                              _studentId = student.id;
                              _focusMostRecentActivity();
                            }),
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
        SliverToBoxAdapter(
          child: constrained(
            Padding(
              padding: EdgeInsets.fromLTRB(side, 0, side, side + navClearance),
              child: _calendarSection(),
            ),
          ),
        ),
      ],
    );
  }

  static const _weekdayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  /// Groups the active child's taps by calendar day (year/month/day, local
  /// time already — see AttendanceTap.fromJson) so the month grid can look
  /// up "does this date have activity" and the day-detail panel below it can
  /// look up "what happened that day" from the same map.
  Map<DateTime, List<AttendanceTap>> get _tapsByDate {
    final map = <DateTime, List<AttendanceTap>>{};
    for (final tap in _activeChildTaps) {
      final day = DateTime(
        tap.occurredAt.year,
        tap.occurredAt.month,
        tap.occurredAt.day,
      );
      (map[day] ??= []).add(tap);
    }
    return map;
  }

  void _changeCalendarMonth(int delta) {
    HapticFeedback.selectionClick();
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + delta,
      );
      // A selection from the previous month has no cell to show against
      // once the grid moves on — clearing it avoids a detail panel for a
      // date that's no longer visible above it.
      if (_calendarSelectedDate != null &&
          (_calendarSelectedDate!.year != _calendarMonth.year ||
              _calendarSelectedDate!.month != _calendarMonth.month)) {
        _calendarSelectedDate = null;
      }
    });
  }

  /// Month-grid overview (Logs answers "what happened," this answers "when
  /// did anything happen") — every date with at least one tap gets a
  /// colored dot; tapping a date reveals that day's taps below the grid.
  Widget _calendarSection() {
    return Builder(
      builder: (context) {
        final palette = StationPalette.of(context);
        final tapsByDate = _tapsByDate;
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final firstOfMonth = DateTime(
          _calendarMonth.year,
          _calendarMonth.month,
        );
        final daysInMonth = DateTime(
          _calendarMonth.year,
          _calendarMonth.month + 1,
          0,
        ).day;
        // DateTime.weekday is 1=Mon..7=Sun; the grid header runs Sun..Sat,
        // so Sunday needs 0 leading blanks, Monday needs 1, etc.
        final leadingBlanks = firstOfMonth.weekday % 7;

        final selected = _calendarSelectedDate;
        final selectedTaps = selected == null
            ? const <AttendanceTap>[]
            : (tapsByDate[selected] ?? const <AttendanceTap>[]);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StationCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => _changeCalendarMonth(-1),
                        icon: const Icon(LucideIcons.chevronLeft),
                        tooltip: 'Previous month',
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${_monthName(_calendarMonth.month)} ${_calendarMonth.year}',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            TextButton(
                              onPressed: _jumpToToday,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                'Jump to today',
                                style: TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => _changeCalendarMonth(1),
                        icon: const Icon(LucideIcons.chevronRight),
                        tooltip: 'Next month',
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: palette.green,
                          ),
                        ),
                        Text(
                          'Recorded activity',
                          style: TextStyle(fontSize: 11, color: palette.muted),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      for (final label in _weekdayLabels)
                        Expanded(
                          child: Center(
                            child: Text(
                              label,
                              style: StationFonts.mono(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: palette.muted,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 7,
                        ),
                    itemCount: leadingBlanks + daysInMonth,
                    itemBuilder: (context, index) {
                      if (index < leadingBlanks) return const SizedBox();
                      final day = index - leadingBlanks + 1;
                      final date = DateTime(
                        _calendarMonth.year,
                        _calendarMonth.month,
                        day,
                      );
                      final hasActivity = tapsByDate.containsKey(date);
                      final isToday = date == today;
                      final isSelected = date == selected;

                      return Padding(
                        padding: const EdgeInsets.all(2),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => setState(
                            () => _calendarSelectedDate = isSelected
                                ? null
                                : date,
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: isSelected
                                  ? palette.blue
                                  : isToday
                                  ? palette.inset
                                  : null,
                              border: isToday && !isSelected
                                  ? Border.all(color: palette.blue, width: 1.5)
                                  : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '$day',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isToday || isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isSelected
                                        ? palette.onAccent
                                        : palette.heading,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: hasActivity
                                        ? (isSelected
                                              ? palette.onAccent
                                              : palette.green)
                                        : Colors.transparent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (selected != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      formatTapDate(selected).toUpperCase(),
                      style: StationFonts.mono(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: palette.muted,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                  if (selectedTaps.isEmpty)
                    const StationCard(
                      child: Text('No activity recorded on this date.'),
                    )
                  else
                    for (final tap in selectedTaps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: StationCard(
                          padding: const EdgeInsets.all(14),
                          child: TapRow(tap: tap),
                        ),
                      ),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Tap a highlighted date to see that day\'s activity.',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _monthName(int month) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][month - 1];

  // Capped, not unbounded — the full history always lives one tab over in
  // Attendance, so Updates only needs to surface the most recent handful
  // rather than growing forever.
  static const _maxUpdatesShown = 10;

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
      else ...[
        for (final tap in _taps.take(_maxUpdatesShown))
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
        if (_taps.length > _maxUpdatesShown)
          Center(
            child: TextButton(
              onPressed: () => _navigate(1),
              child: Text(
                'View all ${_taps.length} in Attendance',
              ),
            ),
          ),
      ],
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
      const SectionHeading(title: 'Student credentials'),
      StationCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Need a student\'s login details?',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'We\'ll send the existing credentials by SMS to the verified primary guardian number.',
              style: TextStyle(color: StationPalette.of(context).muted),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _children.isEmpty ? null : _showCredentialRequestSheet,
              icon: const Icon(Icons.sms_outlined),
              label: const Text('Get credentials'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      /*
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
      */
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

