import 'package:flutter/material.dart';
import 'station_theme.dart';

/// Hand-rolled shimmer sweep — a looping highlight band slid across the
/// child via [ShaderMask], avoiding a pub dependency for what's a small,
/// self-contained effect. Wrap any stack of [SkeletonBox]es in this.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [palette.skeletonBase, palette.skeletonHighlight, palette.skeletonBase],
          stops: const [0.35, 0.5, 0.65],
          transform: _SlidingGradient(bounds.width * (_controller.value * 3 - 1)),
        ).createShader(bounds),
        child: child,
      ),
    );
  }
}

class _SlidingGradient extends GradientTransform {
  const _SlidingGradient(this.dx);
  final double dx;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
}

/// A solid placeholder block standing in for text/images while loading.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 8,
  });
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: StationPalette.of(context).skeletonBase,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

class _SkeletonAvatar extends StatelessWidget {
  const _SkeletonAvatar();
  @override
  Widget build(BuildContext context) => Container(
    width: 60,
    height: 60,
    decoration: BoxDecoration(
      color: StationPalette.of(context).skeletonBase,
      shape: BoxShape.circle,
    ),
  );
}

/// Mirrors the shape of the real dashboard (header, hero, avatar strip,
/// recent-activity rows) so the shimmer reads as "this content is loading"
/// rather than a generic spinner.
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonBox(width: 140, height: 10),
        const SizedBox(height: 14),
        const SkeletonBox(width: 210, height: 26),
        const SizedBox(height: 10),
        const SkeletonBox(width: 250, height: 12),
        const SizedBox(height: 24),
        SkeletonBox(width: double.infinity, height: 190, radius: 24),
        const SizedBox(height: 28),
        const SkeletonBox(width: 110, height: 14),
        const SizedBox(height: 14),
        SizedBox(
          height: 92,
          child: Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 14),
                Column(
                  children: const [
                    _SkeletonAvatar(),
                    SizedBox(height: 6),
                    SkeletonBox(width: 44, height: 10),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SkeletonBox(width: double.infinity, height: 168, radius: 18),
        const SizedBox(height: 28),
        const SkeletonBox(width: 130, height: 14),
        const SizedBox(height: 14),
        for (var i = 0; i < 2; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == 1 ? 0 : 16),
            child: SkeletonBox(width: double.infinity, height: 64, radius: 16),
          ),
      ],
    ),
  );
}

/// Mirrors the shape of the grouped attendance list (title, filter chips,
/// a couple of day-header + row groups).
class AttendanceSkeleton extends StatelessWidget {
  const AttendanceSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonBox(width: 150, height: 26),
        const SizedBox(height: 10),
        const SkeletonBox(width: 220, height: 12),
        const SizedBox(height: 20),
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              SkeletonBox(width: 78, height: 32, radius: 16),
            ],
          ],
        ),
        const SizedBox(height: 24),
        for (var group = 0; group < 2; group++) ...[
          SkeletonBox(width: 90, height: 11, radius: 4),
          const SizedBox(height: 12),
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SkeletonBox(width: double.infinity, height: 60, radius: 16),
            ),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );
}
