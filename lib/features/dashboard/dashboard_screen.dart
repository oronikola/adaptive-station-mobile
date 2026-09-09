import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/models.dart';
import '../../design/components.dart';
import '../../design/station_theme.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.children,
    required this.recentTaps,
    required this.onHistory,
    required this.onChild,
  });
  final List<Student> children;
  final List<AttendanceTap> recentTaps;
  final VoidCallback onHistory;
  final ValueChanged<Student> onChild;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String? _selectedChildId;

  @override
  void initState() {
    super.initState();
    _selectedChildId = widget.children.isEmpty ? null : widget.children.first.id;
  }

  @override
  void didUpdateWidget(covariant DashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A previously-selected child can disappear from the list (account
    // switch, or the quiet _refreshChildrenQuietly() catch-up in
    // ParentShell) — fall back to the first child rather than pointing the
    // strip's selection at nothing.
    final stillPresent = widget.children.any(
      (student) => student.id == _selectedChildId,
    );
    if (!stillPresent) {
      _selectedChildId = widget.children.isEmpty
          ? null
          : widget.children.first.id;
    }
  }

  AttendanceTap? _latestFor(Student student) {
    for (final tap in widget.recentTaps) {
      if (tap.student.id == student.id) return tap;
    }
    return null;
  }

  String _heroHeadline() {
    final children = widget.children;
    if (children.isEmpty) return 'No linked children yet';
    final latestByChild = children.map(_latestFor).toList();
    final inCount = latestByChild.where((tap) => tap?.isIn ?? false).length;
    if (inCount == 0) return 'No children tapped in yet';
    if (inCount == children.length) {
      if (children.length == 1) {
        return '${children.first.name.split(' ').first} tapped in';
      }
      if (children.length == 2) return 'Both children tapped in';
      return 'All children tapped in';
    }
    return '$inCount of ${children.length} children tapped in';
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    final recentTaps = widget.recentTaps;
    final palette = StationPalette.of(context);
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final inCount = children
        .where((student) => _latestFor(student)?.isIn ?? false)
        .length;
    final latestTime = recentTaps.isNotEmpty ? recentTaps.first.time : '—';

    Student? selected;
    for (final student in children) {
      if (student.id == _selectedChildId) {
        selected = student;
        break;
      }
    }
    selected ??= children.isEmpty ? null : children.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'YOUR FAMILY, CONNECTED',
          style: TextStyle(
            color: palette.blue,
            letterSpacing: 1.8,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text('Good morning', style: text.headlineMedium),
        const SizedBox(height: 6),
        Text(
          'A little peace of mind for your school day.',
          style: text.bodyMedium?.copyWith(color: palette.muted),
        ),
        const SizedBox(height: 24),
        // Hero summary card — a flat, neutral surface like every other
        // card (no gradient/glow); the only color is the small icon/chip
        // accents, per the minimalist spec.
        StationCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.wb_sunny_outlined, color: palette.muted, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _bannerDate(now),
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 10,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                _heroHeadline(),
                style: text.titleLarge?.copyWith(fontSize: 23),
              ),
              const SizedBox(height: 8),
              Text(
                'Their latest school gate updates, all in one place.',
                style: TextStyle(color: palette.muted, fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  _HeroChip(icon: Icons.check_circle_outline, label: '$inCount tapped in today'),
                  _HeroChip(
                    icon: Icons.schedule,
                    label: 'Latest tap $latestTime',
                    monospace: true,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const SectionHeading(title: 'My children'),
        if (children.isEmpty)
          const StationCard(
            child: Text('No children are linked to your account yet.'),
          )
        else ...[
          // Instagram-Stories-style avatar strip: scales to any family size
          // without the vertical stack of full cards from before — tapping
          // an avatar swaps the detail card below instead of adding another
          // card to the page.
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: children.length,
              separatorBuilder: (context, index) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final student = children[index];
                final tap = _latestFor(student);
                return _ChildAvatarStripItem(
                  student: student,
                  isIn: tap?.isIn ?? false,
                  selected: student.id == _selectedChildId,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    setState(() => _selectedChildId = student.id);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          if (selected != null)
            ChildCard(
              key: ValueKey(selected.id),
              student: selected,
              latestTap: _latestFor(selected),
              onTap: () => widget.onChild(selected!),
            ),
        ],
        const SizedBox(height: 24),
        SectionHeading(
          title: 'Recent activity',
          action: 'View all',
          onAction: widget.onHistory,
        ),
        if (recentTaps.isEmpty)
          const StationCard(child: Text('No attendance recorded yet.'))
        else
          StationCard(
            child: Column(
              children: [
                for (var i = 0; i < recentTaps.length.clamp(0, 2); i++) ...[
                  if (i > 0) const Divider(height: 32),
                  TapRow(tap: recentTaps[i]),
                ],
              ],
            ),
          ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 17, color: palette.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Times shown in Philippine time (GMT+8). Offline kiosk taps appear after the station reconnects.',
                style: TextStyle(fontSize: 11, height: 1.6, color: palette.muted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _bannerDate(DateTime now) {
    const weekdays = [
      'MONDAY',
      'TUESDAY',
      'WEDNESDAY',
      'THURSDAY',
      'FRIDAY',
      'SATURDAY',
      'SUNDAY',
    ];
    const months = [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ];
    return '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({
    required this.icon,
    required this.label,
    this.monospace = false,
  });
  final IconData icon;
  final String label;
  final bool monospace;
  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: palette.green),
        const SizedBox(width: 6),
        Text(
          label,
          style: monospace
              ? StationFonts.mono(fontSize: 11, color: palette.ink)
              : TextStyle(color: palette.ink, fontSize: 11),
        ),
      ],
    );
  }
}

/// One "story ring" avatar in the horizontal child selector — a thin ring
/// signals whether that child is currently tapped in (green) or selected
/// (accent blue), mirroring the outline/filled selection pattern used
/// elsewhere in this app (nav icons) — no glow, just a hairline ring.
class _ChildAvatarStripItem extends StatelessWidget {
  const _ChildAvatarStripItem({
    required this.student,
    required this.isIn,
    required this.selected,
    required this.onTap,
  });
  final Student student;
  final bool isIn;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? palette.blue
                      : (isIn ? palette.green : palette.border),
                  width: selected ? 2.5 : 2,
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  StationAvatar(initials: student.initials),
                  if (isIn)
                    Positioned(
                      right: -7,
                      bottom: -7,
                      child: RadarPulse(color: palette.green, size: 11, ringCount: 2),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              student.name.split(' ').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? palette.heading : palette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChildCard extends StatelessWidget {
  const ChildCard({
    super.key,
    required this.student,
    required this.latestTap,
    required this.onTap,
  });
  final Student student;
  final AttendanceTap? latestTap;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final tap = latestTap;
    final palette = StationPalette.of(context);
    return StationCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StationAvatar(initials: student.initials),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: StatusPill(
                    label: tap == null
                        ? 'No taps yet'
                        : (tap.isIn ? 'Tapped IN' : 'Tapped OUT'),
                    isIn: tap?.isIn ?? true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(student.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(student.className, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.inset,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  tap == null
                      ? Icons.help_outline_rounded
                      : (tap.isIn ? Icons.login_rounded : Icons.logout_rounded),
                  size: 19,
                  color: tap == null
                      ? palette.muted
                      : (tap.isIn ? palette.green : palette.blue),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tap == null
                            ? 'No attendance recorded yet'
                            : '${tap.isIn ? 'Tapped in' : 'Tapped out'} at ${tap.time}',
                        style: StationFonts.mono(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                      if (tap != null)
                        Text(
                          tap.station,
                          style: StationFonts.mono(fontSize: 11, color: palette.muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onTap,
              child: const Text('View attendance'),
            ),
          ),
        ],
      ),
    );
  }
}

class TapRow extends StatelessWidget {
  const TapRow({super.key, required this.tap, this.showDate = false});
  final AttendanceTap tap;
  final bool showDate;
  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    final accent = tap.isIn ? palette.green : palette.blue;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: tap.isIn ? palette.greenTint : palette.blueTint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            tap.isIn ? Icons.login_rounded : Icons.logout_rounded,
            size: 18,
            color: accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${tap.student.name} tapped ${tap.isIn ? 'IN' : 'OUT'}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.heading,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${tap.station} · ${tap.time}',
                style: StationFonts.mono(fontSize: 11.5, color: palette.muted),
              ),
              if (showDate)
                Text(
                  tap.date,
                  style: StationFonts.mono(fontSize: 11.5, color: palette.muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
