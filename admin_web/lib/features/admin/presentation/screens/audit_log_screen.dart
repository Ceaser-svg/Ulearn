import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/core/utils/date_label.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';

/// The privileged-action log.
class AuditLogScreen extends ConsumerWidget {
  const AuditLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminDataTable<AuditEvent>(
      title: 'Audit log',
      subtitle: 'Append-only record of privileged administrative actions.',
      page: ref.watch(adminAuditEventsProvider),
      controller: ref.read(adminAuditEventsProvider.notifier),
      columns: const ['Action', 'Actor', 'Target', 'Context', 'Created'],
      row: (event) => [
        adminCell(event.action),
        // The actor by name, not by identifier: a bare UUID cannot answer the
        // question the log exists to answer.
        adminCell(event.actorLabel),
        adminCell('${event.targetType}: ${event.targetPublicId ?? '—'}'),
        adminCell(
          event.context.entries
              .map((entry) => '${entry.key}=${entry.value}')
              .join(', '),
        ),
        adminCell(formatDateLabel(event.createdAt)),
      ],
    );
  }
}
