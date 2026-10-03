import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/core/utils/date_label.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';

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
      columns: const ['Action', 'Target', 'Created'],
      row: (event) => [
        event.action,
        event.targetType,
        formatDateLabel(event.createdAt),
      ],
    );
  }
}
