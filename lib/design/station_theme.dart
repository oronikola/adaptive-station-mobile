import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Semantic color set for the app — resolved per-theme via [StationPalette.of]
/// rather than compile-time constants, since every color here now differs
/// between light and dark mode. Accent colors (green/blue) are deliberately
/// restricted to small elements (radar-pulse dots, icon glyphs, badges,
/// pills) by convention at each call site — cards/containers only ever use
/// [surface]/[border]/[inset], never an accent, per the minimalist spec.
@immutable
class StationPalette extends ThemeExtension<StationPalette> {
  const StationPalette({
    required this.background,
    required this.surface,
    required this.border,
    required this.inset,
    required this.heading,
    required this.ink,
    required this.muted,
    required this.green,
    required this.greenTint,
    required this.blue,
    required this.blueTint,
    required this.onAccent,
    required this.cardShadow,
    required this.skeletonBase,
    required this.skeletonHighlight,
  });

  /// Scaffold background.
  final Color background;

  /// Card/container fill — flat, no gradient or translucency.
  final Color surface;

  /// Ultra-thin card/divider/input border.
  final Color border;

  /// One level up from [surface] — nested boxes inside a card (e.g. the
  /// last-tap box inside ChildCard), still neutral.
  final Color inset;

  /// High-contrast heading text.
  final Color heading;

  /// Primary body text.
  final Color ink;

  /// Secondary/caption text.
  final Color muted;

  /// "Tapped IN" accent — small elements only (pulse dots, icon glyphs,
  /// badge fills). Never a card/container background.
  final Color green;
  final Color greenTint;

  /// "Tapped OUT" / interactive accent (buttons, links, selected states).
  final Color blue;
  final Color blueTint;

  /// Text/icon color painted on top of a solid accent fill.
  final Color onAccent;

  /// Card elevation shadow — a faint gray in light mode, empty in dark mode
  /// (dark mode relies on the border/background contrast instead).
  final List<BoxShadow> cardShadow;

  final Color skeletonBase;
  final Color skeletonHighlight;

  static const light = StationPalette(
    background: Color(0xFFF9FAFB),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFE5E7EB),
    inset: Color(0xFFF3F4F6),
    heading: Color(0xFF111827),
    ink: Color(0xFF1F2937),
    muted: Color(0xFF6B7280),
    green: Color(0xFF16A34A),
    greenTint: Color(0x1A16A34A),
    blue: Color(0xFF2563EB),
    blueTint: Color(0x1A2563EB),
    onAccent: Color(0xFFFFFFFF),
    cardShadow: [
      BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 4)),
    ],
    skeletonBase: Color(0xFFE5E7EB),
    skeletonHighlight: Color(0xFFF3F4F6),
  );

  static const dark = StationPalette(
    background: Color(0xFF000000),
    surface: Color(0xFF1F2937),
    border: Color(0xFF374151),
    inset: Color(0xFF161B22),
    heading: Color(0xFFF9FAFB),
    ink: Color(0xFFE5E7EB),
    muted: Color(0xFF9CA3AF),
    green: Color(0xFF22C55E),
    greenTint: Color(0x2622C55E),
    blue: Color(0xFF3B82F6),
    blueTint: Color(0x263B82F6),
    onAccent: Color(0xFFFFFFFF),
    cardShadow: [],
    skeletonBase: Color(0xFF1F2937),
    skeletonHighlight: Color(0xFF374151),
  );

  static StationPalette of(BuildContext context) =>
      Theme.of(context).extension<StationPalette>() ?? light;

  @override
  StationPalette copyWith({
    Color? background,
    Color? surface,
    Color? border,
    Color? inset,
    Color? heading,
    Color? ink,
    Color? muted,
    Color? green,
    Color? greenTint,
    Color? blue,
    Color? blueTint,
    Color? onAccent,
    List<BoxShadow>? cardShadow,
    Color? skeletonBase,
    Color? skeletonHighlight,
  }) => StationPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    border: border ?? this.border,
    inset: inset ?? this.inset,
    heading: heading ?? this.heading,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    green: green ?? this.green,
    greenTint: greenTint ?? this.greenTint,
    blue: blue ?? this.blue,
    blueTint: blueTint ?? this.blueTint,
    onAccent: onAccent ?? this.onAccent,
    cardShadow: cardShadow ?? this.cardShadow,
    skeletonBase: skeletonBase ?? this.skeletonBase,
    skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
  );

  @override
  StationPalette lerp(ThemeExtension<StationPalette>? other, double t) {
    if (other is! StationPalette) return this;
    return StationPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
      heading: Color.lerp(heading, other.heading, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      green: Color.lerp(green, other.green, t)!,
      greenTint: Color.lerp(greenTint, other.greenTint, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      blueTint: Color.lerp(blueTint, other.blueTint, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      cardShadow: t < 0.5 ? cardShadow : other.cardShadow,
      skeletonBase: Color.lerp(skeletonBase, other.skeletonBase, t)!,
      skeletonHighlight: Color.lerp(skeletonHighlight, other.skeletonHighlight, t)!,
    );
  }
}

/// Monospaced text for anything that reads as "data" — timestamps, dates,
/// station codes, RFID/device identifiers — set apart from the general UI's
/// Plus Jakarta Sans to signal "this is a precise, machine-readable value".
abstract final class StationFonts {
  static TextStyle mono({
    required Color color,
    double fontSize = 12,
    FontWeight fontWeight = FontWeight.w500,
    double? letterSpacing,
    double? height,
  }) => GoogleFonts.jetBrainsMono(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

abstract final class StationTheme {
  static ThemeData get light => _build(Brightness.light, StationPalette.light);
  static ThemeData get dark => _build(Brightness.dark, StationPalette.dark);

  static ThemeData _build(Brightness brightness, StationPalette palette) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Plus Jakarta Sans',
    scaffoldBackgroundColor: palette.background,
    extensions: [palette],
    colorScheme: ColorScheme.fromSeed(
      seedColor: palette.blue,
      brightness: brightness,
    ).copyWith(
      primary: palette.blue,
      onPrimary: palette.onAccent,
      secondary: palette.green,
      surface: palette.surface,
      onSurface: palette.ink,
    ),
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w700,
        color: palette.heading,
        letterSpacing: -0.8,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: palette.heading,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: palette.heading,
      ),
      bodyMedium: TextStyle(fontSize: 13, height: 1.6, color: palette.ink),
      bodySmall: TextStyle(fontSize: 12, height: 1.5, color: palette.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.blue,
        foregroundColor: palette.onAccent,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: 'Plus Jakarta Sans',
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.ink,
        minimumSize: const Size(48, 48),
        side: BorderSide(color: palette.border),
        shape: const StadiumBorder(),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.inset,
      selectedColor: palette.blueTint,
      labelStyle: TextStyle(
        color: palette.ink,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      side: BorderSide(color: palette.border),
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.inset,
      contentPadding: const EdgeInsets.all(16),
      labelStyle: TextStyle(color: palette.muted),
      hintStyle: TextStyle(color: palette.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.blue, width: 2),
      ),
    ),
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
  );
}
