import 'package:flutter/material.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';

/// A competency's status as a coloured pill.
///
/// Coloured, because a queue is scanned rather than read: an operator looking
/// for what is waiting should find it without reading every row's status text.
/// The colour is not the only signal -- the label is always present, and it is
/// always the same words -- so the queue still reads correctly in greyscale, to
/// a colour-blind operator, or on a screen the colour failed to reach.
class AdminStatusChip extends StatelessWidget {
  const AdminStatusChip(this.status, {required this.label, super.key});

  final CompetencyStatus status;

  /// What to write on the chip.
  ///
  /// Passed in rather than taken from [status] because a status this build does
  /// not know is displayed as the server spelled it, not as "Unknown".
  final String label;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _tone(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
      ),
    );
  }

  (Color, Color) _tone(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // `surfaceContainerHighest` and `onSurfaceVariant` rather than fixed hexes:
    // they are the container and on-container roles, so the chip stays legible
    // if the seed colour ever changes.
    return switch (status) {
      CompetencyStatus.pending => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      CompetencyStatus.verified => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      CompetencyStatus.rejected => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      // Not a failure tone. An unrecognised status is a newer server, not a
      // problem, and painting it red would alarm an operator about a deploy.
      CompetencyStatus.unknown => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
  }
}

/// A short note beside a value, in the muted tone.
///
/// Used for the grade-versus-bar line and the rejection reason: context that
/// belongs with a row but is not the row's primary value, and must not compete
/// with it for the reader's attention.
class AdminRowNote extends StatelessWidget {
  const AdminRowNote(this.text, {this.icon, super.key});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: AdminColors.muted);
    if (icon == null) {
      return Text(
        text,
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AdminColors.muted),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: style,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
