import 'package:flutter/material.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';

/// Where one tutor proof has got to, labelled in words and coloured by how much
/// it means.
///
/// The same shape as `TutorStandingChip` and `SessionStatusChip`, deliberately.
/// A claim and a standing are both things a tutor waits on, and a chip that
/// looked different on the applications screen than on the rail would be two
/// things to keep consistent for no reason.
///
/// The colours are decoration, not meaning: a status a user has to decode from a
/// colour is one they cannot read, which is why the label is always present. A
/// rejected claim is coloured as a problem rather than as a neutral state,
/// because it is the one row on this screen a tutor is meant to act on. An
/// unrecognised status falls back to the API's own word rather than being
/// hidden, so a state added after this release shows up as unfamiliar instead of
/// as no state at all.
class TutorClaimStatusChip extends StatelessWidget {
  const TutorClaimStatusChip({required this.claim, super.key});

  final TutorClaim claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = _colours(theme);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.sm,
        vertical: AppDimens.xxs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
      ),
      child: Text(
        claim.statusLabel,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }

  (Color, Color) _colours(ThemeData theme) {
    final scheme = theme.colorScheme;
    return switch (claim.status) {
      // Verified is the state the platform is trying to produce, so it is the one
      // that reads as the positive case.
      TutorClaimStatus.verified => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      // With a reviewer. Neutral rather than encouraging: nothing has been
      // decided, and a colour here would imply otherwise.
      TutorClaimStatus.pending => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      // Refused, and actionable. The one row on this screen the tutor is meant
      // to do something about.
      TutorClaimStatus.rejected ||
      null => (scheme.errorContainer, scheme.onErrorContainer),
    };
  }
}
