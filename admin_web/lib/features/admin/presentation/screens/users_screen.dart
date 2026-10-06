import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/utils/date_label.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';

/// The pilot user list.
class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminDataTable<AdminUser>(
      title: 'Pilot users',
      subtitle: 'Operational visibility for invited students and tutors.',
      page: ref.watch(adminUsersProvider),
      controller: ref.read(adminUsersProvider.notifier),
      columns: const ['Name', 'Email', 'Roles', 'Status', 'Created'],
      row: (user) => [
        adminCell(user.name ?? 'Unnamed account'),
        adminCell(user.email),
        adminCell(user.roles.join(', ')),
        adminCell(user.isActive ? 'Active' : 'Inactive'),
        adminCell(formatDateLabel(user.createdAt)),
      ],
    );
  }
}
