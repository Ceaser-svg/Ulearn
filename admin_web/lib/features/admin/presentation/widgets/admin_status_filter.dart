import 'package:flutter/material.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';

/// A dropdown that narrows the review queue to one status.
///
/// "All" is the first option and the default, because opening the queue on a
/// filtered view would hide work without saying so. Selecting a different value
/// reports the intent up; deciding what that means for the current page belongs
/// to the controller, which is the only place that knows where the rows are.
class AdminStatusFilter extends StatelessWidget {
  const AdminStatusFilter({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// The status currently narrowing the list, or null for every status.
  final CompetencyStatus? selected;

  final ValueChanged<CompetencyStatus?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Show',
          style: Theme.of(context).textTheme.labelLarge
              ?.copyWith(color: AdminColors.muted),
        ),
        const SizedBox(width: 8),
        DropdownButton<CompetencyStatus?>(
          value: selected,
          // A fixed item count rather than the length of `CompetencyStatus`: the
          // `unknown` case is something the server may send but not something an
          // operator can meaningfully filter to, since this build cannot name it.
          items: [
            const DropdownMenuItem<CompetencyStatus?>(
              child: Text('All statuses'),
            ),
            // Not const: a `for` over a list of enum values is not a constant
            // expression, and freezing the options here would only pin values
            // the server owns.
            for (final status in CompetencyStatus.filterable)
              DropdownMenuItem<CompetencyStatus?>(
                value: status,
                child: Text(status.label),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }
}
