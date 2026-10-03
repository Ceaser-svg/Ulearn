/// Spacing and radius scale for the client.
///
/// Gaps are declared as constants rather than inline literals so that vertical
/// rhythm stays consistent between screens. The scale is a 4pt grid, which
/// divides evenly into both the compact phone layouts the pilot targets and
/// tablet widths.
abstract final class AppDimens {
  /// Extra extra small: 2pt. Hairline separation only.
  static const double xxs = 2;

  /// Extra small: 4pt. Between an icon and its label.
  static const double xs = 4;

  /// Small: 8pt. Default gap inside a component.
  static const double sm = 8;

  /// Medium: 12pt. Default gap between components.
  static const double md = 12;

  /// Large: 16pt. Screen edge padding on compact layouts.
  static const double lg = 16;

  /// Extra large: 24pt. Between groups of related content.
  static const double xl = 24;

  /// Extra extra large: 32pt. Between distinct sections.
  static const double xxl = 32;

  /// Corner radius for small components such as chips and badges.
  static const double radiusSm = 4;

  /// Corner radius for cards and sheets. The default.
  static const double radiusMd = 12;

  /// Corner radius for dialogs and modal surfaces.
  static const double radiusLg = 20;

  /// Standard horizontal padding applied to every screen.
  static const double screenPadding = lg;

  /// Maximum width for a readable column on tablets and the web target.
  ///
  /// The pilot is mobile-first, so this only prevents line lengths becoming
  /// unreadable when the same widgets render wide.
  static const double maxContentWidth = 640;

  /// Maximum splash animation size on tablets and web.
  static const double splashAnimationMax = 320;

  /// Portion of the available splash viewport used by the animation.
  static const double splashAnimationFraction = 0.55;

  /// Maximum width of the sign-in animation.
  static const double signInAnimationMax = 160;

  /// Maximum bounds of the sign-up animation.
  static const double signUpAnimationMaxWidth = 180;
  static const double signUpAnimationMaxHeight = 145;
}
