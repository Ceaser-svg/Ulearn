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
class CompetenciesScreen extends ConsumerStatefulWidget {
  const CompetenciesScreen({super.key});

  @override
  ConsumerState<CompetenciesScreen> createState() => _CompetenciesScreenState();
}

class _CompetenciesScreenState extends ConsumerState<CompetenciesScreen> {
  /// The competencies with a review in flight.
  ///
  /// A review is a write with no idempotency key, so a second tap while the first
  /// is waiting is not a no-op: it sends a second decision for a record the server
  /// has already moved on from, which fails, or -- worse for a rejection -- records
  /// a second rejection reason. The buttons are disabled for the row while it is
  /// busy, and the whole row's actions are removed so the operator sees the row is
  /// decided rather than a pair of controls that might work.
  final Set<String> _reviewing = <String>{};

  @override
  Widget build(BuildContext context) {
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
      actions: _actions,
    );
  }

  List<Widget> _actions(AdminCompetency competency, VoidCallback refresh) {
    if (competency.status != 'pending') return const <Widget>[];
    if (_reviewing.contains(competency.id)) {
      return const [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ];
    }

    return [
      TextButton(
        onPressed: () => _review(
          competency,
          refresh,
          action: (repository) => repository.verify(competency),
          onSuccess: 'Competency verified.',
        ),
        child: const Text('Verify'),
      ),
      TextButton(
        onPressed: () => _reject(competency, refresh),
        child: const Text('Reject'),
      ),
    ];
  }

  Future<void> _reject(
    AdminCompetency competency,
    VoidCallback refresh,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const RejectionReasonDialog(),
    );
    // Null is a deliberate cancellation, which is not a failure and needs no
    // message. The dialog itself refuses to return an empty reason.
    if (reason == null) return;
    if (!mounted) return;
    await _review(
      competency,
      refresh,
      action: (repository) => repository.reject(competency, reason),
      onSuccess: 'Competency rejected.',
    );
  }

  Future<void> _review(
    AdminCompetency competency,
    VoidCallback refresh, {
    required Future<void> Function(CompetencyReviewController repository) action,
    required String onSuccess,
  }) async {
    if (_reviewing.contains(competency.id)) return;

    setState(() => _reviewing.add(competency.id));
    try {
      await action(ref.read(competencyReviewControllerProvider));
    } on AdminReviewException catch (error) {
      if (mounted) _notify(context, error.message);
      return;
    } finally {
      if (mounted) setState(() => _reviewing.remove(competency.id));
    }

    if (!mounted) return;
    // Re-read the list first: a competency that has just been decided must not
    // still be offering its own buttons.
    refresh();
    _notify(context, onSuccess);
  }

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
