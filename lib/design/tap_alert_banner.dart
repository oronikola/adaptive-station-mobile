import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import 'components.dart';
import 'station_theme.dart';

/// A heads-up-style banner for a live tap update — slides in from the top of
/// the screen and auto-dismisses. Flutter's built-in SnackBar is anchored to
/// the bottom only, which reads as a generic toast rather than a
/// notification; this is meant to feel like the real thing.
abstract final class TapAlertBanner {
  static void show(
    BuildContext context, {
    required AttendanceTap tap,
    VoidCallback? onTap,
  }) {
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TapAlertBannerWidget(
        tap: tap,
        onDismiss: () {
          if (entry.mounted) entry.remove();
        },
        onTap: () {
          if (entry.mounted) entry.remove();
          onTap?.call();
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
  }
}

class _TapAlertBannerWidget extends StatefulWidget {
  const _TapAlertBannerWidget({
    required this.tap,
    required this.onDismiss,
    required this.onTap,
  });
  final AttendanceTap tap;
  final VoidCallback onDismiss;
  final VoidCallback onTap;

  @override
  State<_TapAlertBannerWidget> createState() => _TapAlertBannerWidgetState();
}

class _TapAlertBannerWidgetState extends State<_TapAlertBannerWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: const Offset(0, -1.2),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _autoDismiss = Timer(const Duration(seconds: 5), _dismiss);
  }

  Future<void> _dismiss() async {
    _autoDismiss?.cancel();
    if (!mounted) return;
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tap = widget.tap;
    final palette = StationPalette.of(context);
    final accent = tap.isIn ? palette.green : palette.blue;
    final tint = tap.isIn ? palette.greenTint : palette.blueTint;
    final subtitle = [
      if (tap.station.isNotEmpty) tap.station,
      tap.time,
    ].join(' · ');

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: SlideTransition(
          position: _offset,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: widget.onTap,
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) < 0) _dismiss();
                },
                child: StationCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          tap.isIn ? Icons.login_rounded : Icons.logout_rounded,
                          color: accent,
                          size: 20,
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
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: palette.heading,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: StationFonts.mono(
                                fontSize: 11.5,
                                color: palette.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: _dismiss,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: palette.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
