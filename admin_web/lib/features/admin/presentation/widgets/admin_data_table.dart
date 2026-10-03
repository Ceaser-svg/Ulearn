import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_list_controller.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_pagination_bar.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_card.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';

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
    this.actions,
    super.key,
  });

  final String title;
  final String subtitle;

  /// The list's current state, watched by the screen that built the table.
  final AsyncValue<AdminPage<T>> page;

  final AdminListController<T> controller;
  final List<String> columns;
  final List<String> Function(T item) row;

  /// Per-row actions. Null when the list has none, which is also what leaves
  /// the actions column out of the table.
  final List<Widget> Function(T item, VoidCallback refresh)? actions;

  @override
  State<AdminDataTable<T>> createState() => _AdminDataTableState<T>();
}

class _AdminDataTableState<T> extends State<AdminDataTable<T>> {
  /// Below this, columns stop being columns.
  static const double _narrowBreakpoint = 720;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < _narrowBreakpoint;
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
              Expanded(child: _body(narrow)),
            ],
          ),
        );
      },
    );
  }

  Widget _body(bool narrow) {
    return widget.page.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) =>
          _LoadFailedView(onRetry: widget.controller.refresh),
      data: (page) => _records(page, narrow),
    );
  }

  Widget _records(AdminPage<T> page, bool narrow) {
    if (page.isEmpty) {
      return const Center(child: Text('No records yet.'));
    }
    final rows = <List<String>>[
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

class _LoadFailedView extends StatelessWidget {
  const _LoadFailedView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not load this view.'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
