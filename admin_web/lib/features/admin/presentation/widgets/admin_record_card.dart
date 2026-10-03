import 'package:flutter/material.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';

/// One record as a labelled stack, for windows too narrow for columns.
///
/// A table is the wrong shape below about 720 logical pixels: the columns stop
/// being columns and start being a horizontal scroll nobody finds. Labelling
/// each value with its column keeps the same information on screen without it,
/// and gives a screen reader the label and the value as one phrase instead of
/// as two disconnected cells.
class AdminRecordCard extends StatelessWidget {
  const AdminRecordCard({
    required this.columns,
    required this.values,
    this.actions = const <Widget>[],
    super.key,
  });

  final List<String> columns;

  /// One entry per [columns].
  final List<String> values;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: AdminColors.muted);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < values.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Semantics(
                  label: '${columns[index]}: ${values[index]}',
                  child: ExcludeSemantics(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${columns[index]}  ',
                            style: labelStyle,
                          ),
                          TextSpan(text: values[index]),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
