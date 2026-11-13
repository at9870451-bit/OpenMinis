import 'package:flutter/material.dart';

/// Apple Native White tokens. One source of truth for the whole app — no
/// gradients anywhere, one grey family, one accent.
class AmoreTheme {
  // Surfaces
  static const background = Color(0xFFFFFFFF);
  static const secondaryBackground = Color(0xFFF5F5F7);
  static const groupedBackground = Color(0xFFF2F2F7);

  // Text
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF8E8E93);
  static const textDisabled = Color(0xFFC7C7CC);

  // Lines / accent
  static const separator = Color(0xFFE5E5EA);
  static const accent = Color(0xFF007AFF);
  static const warning = Color(0xFFFF9500);
  static const danger = Color(0xFFFF3B30);

  // Radii
  static const double rChip = 12;
  static const double rCard = 20;
  static const double rPanel = 24;
  static const double rScreen = 28;

  /// Glass fill used on floating surfaces. Kept light so the Material blur
  /// behind it stays visible instead of flattening into a solid panel.
  static Color glass([double opacity = 0.72]) =>
      Colors.white.withValues(alpha: opacity);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.light,
        surface: background,
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      dividerColor: separator,
    );
  }
}
