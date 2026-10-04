import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_tutor_standing.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';

/// Tutor standing and rating aggregates.
class TutorStandingsScreen extends ConsumerWidget {
  const TutorStandingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminDataTable<AdminTutorStanding>(
      title: 'Tutor standing',
      subtitle: 'Review current standing and rating aggregates.',
      page: ref.watch(adminTutorStandingsProvider),
      controller: ref.read(adminTutorStandingsProvider.notifier),
      columns: const ['Tutor', 'Standing', 'Sessions', 'Average rating'],
      row: (standing) => [
        standing.name ?? standing.email,
        standing.standing,
        '${standing.sessions}',
        standing.rating ?? 'Unrated',
      ],
    );
  }
}
