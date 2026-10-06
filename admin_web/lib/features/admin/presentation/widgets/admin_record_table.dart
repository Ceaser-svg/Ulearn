import 'package:flutter/material.dart';

/// The wide-window form of a record list: a header row and one row per record.
///
/// Every column takes a flexible share of the width the table is given and
/// every cell clips instead of pushing the table wider, so a long email cannot
/// force the table past its pane. Narrow windows use `AdminRecordCard` instead;
/// a table that only works on a desktop is a table that cannot be used from a
/// phone-sized browser window at all.
class AdminRecordTable extends StatelessWidget {
  const AdminRecordTable({
    required this.columns,
    required this.rows,
    this.buildActions,
    super.key,
  });

  final List<String> columns;

  /// One entry per row, each the same length as [columns].
  ///
  /// Widgets rather than strings because a cell is not always a word: a status
  /// is a coloured pill and a grade carries a note under it. Clipping is applied
  /// by [adminCell] so a plain value cannot push the table past its pane, while
  /// a cell that brings its own widget stays as wide as it needs to be.
  final List<List<Widget>> rows;

  /// The row actions for a row, by index. Null when the list has none.
  final List<Widget> Function(int index)? buildActions;

  @override
  Widget build(BuildContext context) {
    final headers = <String>[...columns, if (buildActions != null) 'Actions'];
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: DataTable(
          // Cells are widgets, and a cell may need two lines -- a grade beside
          // the bar it has to clear, a refusal reason. `dataRowHeight` pins the
          // row to exactly `kMinInteractiveDimension`, which lays such a cell
          // out into a height it does not fit and overflows it by a few pixels.
          // A minimum keeps the tap target; the maximum lets the row grow to
          // whatever its tallest cell actually needs.
          dataRowMinHeight: kMinInteractiveDimension,
          dataRowMaxHeight: _maxRowHeight,
          columns: [
            for (final header in headers)
              DataColumn(
                // Flexible, and clipped, so a header shrinks instead of pinning
                // the column to its own width. Without it the header row is
                // what overflows a panel too narrow for the columns, where the
                // values below would only have ellipsised.
                label: Flexible(
                  child: Text(
                    header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
                columnWidth: const FlexColumnWidth(),
              ),
          ],
          rows: [
            for (var index = 0; index < rows.length; index++)
              DataRow(
                cells: [
                  for (final cell in rows[index]) DataCell(cell),
                  if (buildActions != null)
                    DataCell(Wrap(spacing: 8, children: buildActions!(index))),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Ceiling on a record row's height, past which a cell should have been given a
/// column of its own instead of wrapping further.
const double _maxRowHeight = 200;

/// A table cell holding [value], clipped the way a table cell has to be.
///
/// Shared so that the narrow-window card and the wide table clip identically: a
/// value that fits in the table and overflows the card would be a bug that only
/// appears on the layout nobody tests.
Widget adminCell(String value) =>
    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis);
