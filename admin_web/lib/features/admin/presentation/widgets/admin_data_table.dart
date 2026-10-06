import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_list_controller.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_pagination_bar.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_card.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_state_views.dart';

/// One paged admin list: a heading, the records, and the pager.
///
/// A view and nothing else. It is handed the list's current state and the
/// controller that owns the page, so it renders rows and emits intents without
/// deciding what a page is or which one comes next.
class AdminDataTable<T> extends StatefulWidget {
  const AdminDataTable({
    required this.title,
    required this.subtitle,
    required this.page,
    required this.controller,
    required this.columns,
    required this.row,
    this.narrowBreakpoint = _defaultNarrowBreakpoint,
    this.spokenRow,
    this.actions,
    this.toolbar,
    this.emptyMessage,
    super.key,
  });

  final String title;
  final String subtitle;

  /// The list's current state, watched by the screen that built the table.
  final AsyncValue<AdminPage<T>> page;

  final AdminListController<T> controller;
  final List<String> columns;

  /// One row's cells, in [columns] order.
  final List<Widget> Function(T item) row;

  /// Width below which columns become a labelled card.
  ///
  /// A screen with a wide table raises this. The default suits the console's
  /// three- and four-column lists, where a phone is the narrowest window worth
  /// supporting; a table with eight columns stops being legible long before it
  /// stops fitting, and squeezing it produces a row of ellipses.
  final double narrowBreakpoint;

  /// What each of a row's cells is announced as, in [columns] order.
  ///
  /// Only the narrow-window card reads this. It exists because a cell can now
  /// be a widget that says nothing in text -- a status is a pill -- and the
  /// card pairs each value with its heading in one announced node, so a cell
  /// left to speak for itself is announced as a bare heading. Null for a list
  /// whose cells are all plain text, which is the case for every console list
  /// except the review queue.
  final List<String>? Function(T item)? spokenRow;

  /// Per-row actions. Null when the list has none, which is also what leaves
  /// the actions column out of the table.
  final List<Widget> Function(T item, VoidCallback refresh)? actions;

  /// Controls shown between the heading and the records, e.g. a filter.
  ///
  /// A slot rather than a special case so that narrowing a list is not a
  /// capability one screen has and the others cannot have.
  final Widget? toolbar;

  /// What to say when the list is empty.
  ///
  /// Defaults to the console-wide wording. A filtered list overrides it, because
  /// "no records" is a different fact when a filter is in play and an operator
  /// needs to be able to tell the two apart.
  final String? emptyMessage;

  @override
  State<AdminDataTable<T>> createState() => _AdminDataTableState<T>();
}

/// Below this, columns stop being columns.
const double _defaultNarrowBreakpoint = 720;

class _AdminDataTableState<T> extends State<AdminDataTable<T>> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < widget.narrowBreakpoint;
        return Padding(
          padding: EdgeInsets.all(narrow ? 16 : 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AdminColors.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AdminColors.muted,
                ),
              ),
              const SizedBox(height: 24),
              if (widget.toolbar != null) ...[
                widget.toolbar!,
                const SizedBox(height: 16),
              ],
              Expanded(child: _body(narrow)),
            ],
          ),
        );
      },
    );
  }

  Widget _body(bool narrow) {
    return widget.page.when(
      loading: () => AdminLoadingView(what: _what),
      error: (error, stackTrace) =>
          AdminLoadFailedView(onRetry: widget.controller.refresh),
      data: (page) => _records(page, narrow),
    );
  }

  /// Noun for the loading view's wording, taken from the heading so the sentence
  /// matches the screen the operator is looking at.
  String get _what {
    final heading = widget.title.toLowerCase();
    return heading.endsWith('s') ? heading : '${heading}s';
  }

  Widget _records(AdminPage<T> page, bool narrow) {
    if (page.isEmpty && page.total == 0) {
      return AdminEmptyView(
        emptyMessage: widget.emptyMessage ?? 'No records yet.',
      );
    }
    final rows = <List<Widget>>[
      for (final item in page.items) widget.row(item),
    ];
    List<Widget> actionsAt(int index) =>
        widget.actions?.call(page.items[index], widget.controller.refresh) ??
        const <Widget>[];
    return Column(
      children: [
        Expanded(
          child: narrow
              ? ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) => AdminRecordCard(
                    columns: widget.columns,
                    values: rows[index],
                    spokenValues: widget.spokenRow == null
                        ? null
                        : widget.spokenRow!(page.items[index]),
                    actions: actionsAt(index),
                  ),
                )
              : AdminRecordTable(
                  columns: widget.columns,
                  rows: rows,
                  buildActions: widget.actions == null ? null : actionsAt,
                ),
        ),
        const SizedBox(height: 16),
        AdminPaginationBar<T>(
          page: page,
          request: widget.controller.request,
          onChanged: widget.controller.show,
        ),
      ],
    );
  }
}
