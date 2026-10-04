import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/competency_review_controller.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/rejection_reason_dialog.dart';

/// Competency review, and the console's only write.
///
/// The screen decides what the operator is told; [CompetencyReviewController]
/// decides what the server was asked. A review only offers actions while the
/// competency is pending, because the backend owns the status transition and
/// offering to verify an already-verified competency would be a button that
/// cannot succeed.
class CompetenciesScreen extends ConsumerWidget {
  const CompetenciesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminDataTable<AdminCompetency>(
      title: 'Competency review',
      subtitle: 'Review tutor evidence before granting matching eligibility.',
      page: ref.watch(adminCompetenciesProvider),
      controller: ref.read(adminCompetenciesProvider.notifier),
      columns: const ['Tutor', 'Unit', 'Grade', 'Status', 'Evidence'],
      row: (competency) => [
        competency.name ?? competency.email,
        competency.unit,
        competency.grade,
        competency.status,
        competency.evidence ?? 'Not supplied',
      ],
      actions: (competency, refresh) => competency.status == 'pending'
          ? [
              TextButton(
                onPressed: () => _review(
                  context,
                  ref,
                  verify: () => ref
                      .read(competencyReviewControllerProvider)
                      .verify(competency),
                  refresh: refresh,
                ),
                child: const Text('Verify'),
              ),
              TextButton(
                onPressed: () async {
                  final reason = await showDialog<String>(
                    context: context,
                    builder: (context) => const RejectionReasonDialog(),
                  );
                  if (reason == null || reason.trim().isEmpty) return;
                  if (!context.mounted) return;
                  await _review(
                    context,
                    ref,
                    verify: () => ref
                        .read(competencyReviewControllerProvider)
                        .reject(competency, reason.trim()),
                    refresh: refresh,
                  );
                },
                child: const Text('Reject'),
              ),
            ]
          : const <Widget>[],
    );
  }

  Future<void> _review(
    BuildContext context,
    WidgetRef ref, {
    required Future<CompetencyReviewOutcome> Function() verify,
    required VoidCallback refresh,
  }) async {
    CompetencyReviewOutcome outcome;
    try {
      outcome = await verify();
    } on AdminValidationException catch (error) {
      if (context.mounted) _notify(context, error.message);
      return;
    }
    if (!context.mounted) return;
    if (outcome == CompetencyReviewOutcome.failed) {
      _notify(context, 'Could not record the review. Try again.');
      return;
    }
    // Re-read the list first: a competency that has just been decided must not
    // still be offering its own buttons.
    refresh();
    _notify(
      context,
      outcome == CompetencyReviewOutcome.verified
          ? 'Competency verified.'
          : 'Competency rejected.',
    );
  }

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
