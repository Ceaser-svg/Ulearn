import 'package:flutter/material.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';

/// The controls under a record list: where you are, and how to get elsewhere.
///
/// `total` is shown next to the range on screen rather than left in the
/// response, because "1-50" on its own reads as the whole answer and hides the
/// rows an operator has not reached yet. Live region so a page change is
/// announced rather than silently swapped under the reader.
class AdminPaginationBar<T> extends StatelessWidget {
  const AdminPaginationBar({
    required this.page,
    required this.request,
    required this.onChanged,
    super.key,
  });

  final AdminPage<T> page;
  final AdminPageRequest request;
  final ValueChanged<AdminPageRequest> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Semantics(
      liveRegion: true,
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Showing ${page.firstRowNumber}-${page.lastRowNumber} of ${page.total}',
            style: muted,
          ),
          Text('Page ${page.pageNumber} of ${page.pageCount}', style: muted),
          TextButton(
            onPressed: request.page <= 1
                ? null
                : () => onChanged(request.previous),
            child: const Text('Previous'),
          ),
          TextButton(
            onPressed: page.hasMore ? () => onChanged(request.next) : null,
            child: const Text('Next'),
          ),
          _PageSizePicker(request: request, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _PageSizePicker extends StatelessWidget {
  const _PageSizePicker({required this.request, required this.onChanged});

  final AdminPageRequest request;
  final ValueChanged<AdminPageRequest> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Rows per page',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<int>(
          value: request.limit,
          borderRadius: BorderRadius.circular(8),
          items: [
            for (final size in AdminPageRequest.pageSizeOptions)
              DropdownMenuItem<int>(value: size, child: Text('$size')),
          ],
          onChanged: (size) {
            if (size != null) onChanged(request.withLimit(size));
          },
        ),
      ],
    );
  }
}
