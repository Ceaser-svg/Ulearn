import 'package:flutter/material.dart';

/// The console palette.
///
/// Four colours cover every surface in the console, so they are named
/// constants rather than theme colour roles: at this size a role lookup per
/// widget is noise, and an operations console is not going to grow a dark
/// theme that would earn one.
abstract final class AdminColors {
  /// Headings and any text that has to clear the muted tone at small sizes.
  static const Color ink = Color(0xFF172033);

  /// Secondary text: subtitles, and the labels on a record card.
  static const Color muted = Color(0xFF667085);

  /// Brand accent. Seeds the colour scheme and colours the wordmark.
  static const Color accent = Color(0xFF2457D6);

  /// Page background behind the cards.
  static const Color surface = Color(0xFFF7F9FC);
}

/// Builds the single theme the console runs with.
ThemeData buildAdminTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: AdminColors.accent),
  scaffoldBackgroundColor: AdminColors.surface,
  fontFamily: 'Arial',
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(),
  ),
);
