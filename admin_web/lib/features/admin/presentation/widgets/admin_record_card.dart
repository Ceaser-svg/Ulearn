import 'package:flutter/material.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';

/// One record as a labelled stack, for windows too narrow for columns.
///
/// A table is the wrong shape below about 720 logical pixels: the columns stop
/// being columns and start being a horizontal scroll nobody finds. Labelling
/// each value with its column keeps the same information on screen without it.
///
/// [spokenValues] exists because the visible text and what a screen reader says
/// stopped being the same thing once cells became widgets. A status is a pill
/// with no text of its own to read out, so a heading and a cell that are
/// announced separately would leave the operator hearing "Status" and then
/// nothing. Each entry pairs with [values] at the same index; it is supplied
/// rather than guessed from the widget because the only reliable way to know
/// what a cell says is to be told.
class AdminRecordCard extends StatelessWidget {
  const AdminRecordCard({
    required this.columns,
    required this.values,
    this.spokenValues,
    this.actions = const <Widget>[],
    super.key,
  });

  final List<String> columns;

  /// One entry per [columns]. Widgets so that a status can stay a pill on a
  /// phone-sized window too.
  final List<Widget> values;

  /// What each value is announced as, positionally matching [values].
  ///
  /// Null when the values are plain text and speak for themselves, which is the
  /// case for every list in the console except the review queue.
  final List<String>? spokenValues;

  final List<Widget> actions;

  /// Wide enough for the longest column heading this console uses, so the
  /// values all start at one x. A narrower label column would wrap `Sessions`
  /// and put its values out of line with the rest.
  static const double _labelWidth = 132;

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
                // The heading is announced with the value in one node, so a
                // screen reader hears "Status, pending" rather than a heading
                // and then an unlabelled pill. `ExcludeSemantics` drops the
                // cell's own node because its words are already in this label.
                //
                // `container: true` because these are siblings and identical in
                // configuration: without it they annotate one shared node and
                // every pair after the first is dropped from the tree.
                child: Semantics(
                  container: true,
                  label: spokenValues == null
                      ? '${columns[index]}: ${_plainText(values[index])}'
                      : '${columns[index]}: ${spokenValues![index]}',
                  excludeSemantics: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: _labelWidth,
                        child: Text(columns[index], style: labelStyle),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: values[index]),
                    ],
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

  /// The words a plain text cell shows, or the empty string for a cell that has
  /// none.
  ///
  /// Only ever used when [spokenValues] was not supplied, which is the case for
  /// plain `Text` cells. A cell that is not text is a caller bug that would
  /// announce as a bare heading, and [spokenValues] is the way to not have one.
  String _plainText(Widget cell) =>
      cell is Text ? (cell.data ?? cell.textSpan?.toPlainText() ?? '') : '';
}
