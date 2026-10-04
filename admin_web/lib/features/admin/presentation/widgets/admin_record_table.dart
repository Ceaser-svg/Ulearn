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
  final List<List<String>> rows;

  /// The row actions for a row, by index. Null when the list has none.
  final List<Widget> Function(int index)? buildActions;

  @override
  Widget build(BuildContext context) {
    final headers = <String>[...columns, if (buildActions != null) 'Actions'];
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: DataTable(
          columns: [
            for (final header in headers)
              DataColumn(
                label: Text(header),
                columnWidth: const FlexColumnWidth(),
              ),
          ],
          rows: [
            for (var index = 0; index < rows.length; index++)
              DataRow(
                cells: [
                  for (final value in rows[index])
                    DataCell(
                      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
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
