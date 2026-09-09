import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../services/theme_controller.dart';
import 'station_theme.dart';

/// A flat, minimalist container: a solid surface fill, a hairline border,
/// and (light mode only) a faint gray elevation shadow — no gradients, no
/// blur, no accent-colored glow. Used everywhere a card is needed, so every
/// screen built on [StationCard] stays consistent automatically.
class StationCard extends StatelessWidget {
  const StationCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 18.0,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: palette.border),
        boxShadow: palette.cardShadow,
      ),
      child: child,
    );
  }
}

/// A looping radar ripple — one or more ring outlines expand and fade out
/// around a solid (non-glowing) center dot, on repeat. Signals "this is live
/// right now" for anything backed by the open websocket connection (a child
/// currently tapped in, an active status pill). Deliberately flat — no
/// blurred drop-shadow "glow" on the dot itself, just the ring animation.
class RadarPulse extends StatefulWidget {
  const RadarPulse({
    super.key,
    required this.color,
    this.size = 14,
    this.ringCount = 2,
  });
  final Color color;
  final double size;
  final int ringCount;

  @override
  State<RadarPulse> createState() => _RadarPulseState();
}

class _RadarPulseState extends State<RadarPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.size * 3,
    height: widget.size * 3,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < widget.ringCount; i++) _ring(i),
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
          ),
        ],
      ),
    ),
  );

  Widget _ring(int index) {
    final phase = (_controller.value + index / widget.ringCount) % 1.0;
    final scale = 1 + phase * 2.4;
    final opacity = (1 - phase).clamp(0.0, 1.0) * 0.7;
    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: widget.color, width: 1.4),
          ),
        ),
      ),
    );
  }
}

/// A small status badge — the one place accent color is allowed to fill a
/// background, since it's a compact pill rather than a card/container.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, this.isIn = true});
  final String label;
  final bool isIn;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    final accent = isIn ? palette.green : palette.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isIn ? palette.greenTint : palette.blueTint,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isIn) ...[
            RadarPulse(color: accent, size: 7, ringCount: 1),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

class StationAvatar extends StatelessWidget {
  const StationAvatar({
    super.key,
    required this.initials,
    this.color,
    this.background,
  });
  final String initials;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? palette.blueTint,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Text(
        initials,
        style: TextStyle(
          color: color ?? palette.blue,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
    );
  }
}

/// One nav destination — a single (Lucide) glyph, since the stroke-icon set
/// has no separate outline/filled variants. Active vs. inactive is signaled
/// by color (+ a small neutral pill behind the icon) instead of swapping
/// glyphs.
class StationNavDestination {
  const StationNavDestination({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// A floating, fully-rounded "stadium" navigation bar — detached from the
/// screen edges with margin on all sides, sitting on top of the page content
/// (the parent Scaffold uses `extendBody: true`), icon-only for a clean
/// look, with a minimal neutral pill behind the active icon.
class StationBottomNav extends StatelessWidget {
  const StationBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.badgeCounts = const {},
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<StationNavDestination> destinations;
  final Map<int, int> badgeCounts;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassFill = isDark
        ? Colors.black.withValues(alpha: 0.4)
        : Colors.white.withValues(alpha: 0.65);
    const radius = 50.0;

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
          child: Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: glassFill,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: palette.border),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final itemCount = destinations.length;
                final itemWidth = itemCount > 0 ? constraints.maxWidth / itemCount : 0.0;

                return Stack(
                  children: [
                    // Fluid sliding active indicator pill
                    if (itemCount > 0)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        left: selectedIndex * itemWidth + 4,
                        top: 10,
                        bottom: 10,
                        width: (itemWidth - 8).clamp(0.0, double.infinity),
                        child: Container(
                          decoration: BoxDecoration(
                            color: palette.inset,
                            borderRadius: BorderRadius.circular(50),
                          ),
                        ),
                      ),
                    // Navigation items row
                    Row(
                      children: [
                        for (var i = 0; i < destinations.length; i++)
                          Expanded(
                            child: _StationNavItem(
                              destination: destinations[i],
                              selected: i == selectedIndex,
                              badgeCount: badgeCounts[i] ?? 0,
                              onTap: () => onDestinationSelected(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _StationNavItem extends StatelessWidget {
  const _StationNavItem({
    required this.destination,
    required this.selected,
    required this.badgeCount,
    required this.onTap,
  });
  final StationNavDestination destination;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Tooltip(
      message: destination.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(50),
          ),
          child: Badge(
            isLabelVisible: badgeCount > 0,
            label: Text(badgeCount > 9 ? '9+' : '$badgeCount'),
            backgroundColor: palette.blue,
            textColor: palette.onAccent,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                color: selected ? palette.heading : palette.muted,
              ),
              child: Icon(
                destination.icon,
                size: 22,
                color: selected ? palette.heading : palette.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StationBrand extends StatelessWidget {
  const StationBrand({super.key});
  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Row(
      children: [
        StationAvatar(initials: 'AS', color: Colors.white, background: palette.blue),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Adaptive Station',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: palette.heading,
                  fontSize: 14,
                ),
              ),
              Text(
                'PARENT PORTAL',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.7,
                  color: palette.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Header action that toggles strictly between light and dark (never
/// system) — a caller with a segmented System/Light/Dark control elsewhere
/// (e.g. the parent dashboard's Account tab) leaves "System" reachable only
/// there. Reflects whatever theme is actually active via `Theme.of(context)`
/// (which already rebuilds when [ThemeController] changes the app's
/// resolved brightness), so this needs no listener of its own. Shared by
/// every shell (parent dashboard, gateway-sender) rather than duplicated
/// per screen.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key, required this.themeController});
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
      onPressed: () {
        HapticFeedback.lightImpact();
        themeController.setMode(isDark ? ThemeMode.light : ThemeMode.dark);
      },
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: animation,
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(
          isDark ? LucideIcons.sun : LucideIcons.moon,
          key: ValueKey(isDark),
        ),
      ),
    );
  }
}

/// The Account tab's full System/Light/Dark theme picker — a custom
/// icon-only sliding pill (an iOS-segmented-control look) rather than
/// Flutter's stock [SegmentedButton], which reads as a generic Material
/// widget out of place in this app's minimalist design language. The active
/// icon's backing pill slides between positions instead of the whole
/// control repainting, and colors are theme-aware (both light and dark)
/// rather than following the OS's own light/dark split, since a person
/// picking "Dark" while their OS is in light mode still needs to read this
/// control correctly against whichever brightness has already taken effect.
class ThemeModeSelector extends StatelessWidget {
  const ThemeModeSelector({super.key, required this.themeController});
  final ThemeController themeController;

  static const _modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
  static const _icons = [LucideIcons.smartphone, LucideIcons.sun, LucideIcons.moon];

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeController,
      builder: (context, mode, _) {
        final selectedIndex = _modes.indexOf(mode);

        return Container(
          height: 44,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111827) : Colors.grey.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(50),
          ),
          child: Stack(
            children: [
              AnimatedAlign(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOutCubic,
                alignment: Alignment(-1 + selectedIndex.toDouble(), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / _modes.length,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF374151) : Colors.white,
                      borderRadius: BorderRadius.circular(50),
                      boxShadow: isDark
                          ? const []
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.10),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < _modes.length; i++)
                    Expanded(
                      child: _ThemeModeOption(
                        icon: _icons[i],
                        selected: i == selectedIndex,
                        color: i == selectedIndex ? palette.heading : palette.muted,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          themeController.setMode(_modes[i]);
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThemeModeOption extends StatelessWidget {
  const _ThemeModeOption({
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(50),
      child: SizedBox(
        height: double.infinity,
        child: Center(child: Icon(icon, size: 18, color: color)),
      ),
    ),
  );
}
