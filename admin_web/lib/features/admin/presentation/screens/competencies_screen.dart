import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/utils/date_label.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/competency_review_controller.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_status_chip.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_status_filter.dart';
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
    final controller = ref.read(adminCompetenciesProvider.notifier);
    final filtered = controller.status != null;
    return AdminDataTable<AdminCompetency>(
      title: 'Competency review',
      subtitle: 'Review tutor evidence before granting matching eligibility.',
      page: ref.watch(adminCompetenciesProvider),
      controller: controller,
      columns: const [
        'Tutor',
        'Unit',
        'Grade',
        'Status',
        'Submitted',
        'Reason',
        'Evidence',
      ],
      // The card pairs each value with its heading in one announced node, and
      // three of these cells are widgets with no text of their own to read out:
      // the status pill, the grade beside its bar, and the refusal reason.
      // Said here, in the screen that decided the wording.
      spokenRow: (competency) => [
        competency.name ?? competency.email,
        competency.unit,
        competency.thresholdSummary ?? 'No grading scale loaded',
        competency.statusLabel,
        formatDateLabel(competency.submittedAt),
        competency.rejectionReason ??
            (competency.verifiedAt == null ? 'No decision yet' : 'Verified'),
        competency.evidence ?? 'Not supplied',
      ],
      // Seven columns plus actions. Past about a laptop's worth of width they
      // stop being readable and start being a row of ellipses, so this table
      // changes shape earlier than the console's narrower lists do.
      narrowBreakpoint: 1100,
      row: (competency) => [
        adminCell(competency.name ?? competency.email),
        adminCell(competency.unit),
        _grade(competency),
        AdminStatusChip(competency.status, label: competency.statusLabel),
        adminCell(formatDateLabel(competency.submittedAt)),
        _reason(competency),
        adminCell(competency.evidence ?? 'Not supplied'),
      ],
      actions: _actions,
      toolbar: AdminStatusFilter(
        selected: controller.status,
        onChanged: controller.showStatus,
      ),
      // Not the console-wide "No records yet.": an operator who has just worked
      // the pending queue to empty has not discovered anything is broken, and
      // the filter is what tells them which question they are looking at.
      emptyMessage: filtered
          ? 'No ${controller.status!.label.toLowerCase()} competencies.'
          : 'No competencies submitted yet.',
    );
  }

  /// The grade, with the bar it has to clear beside it.
  ///
  /// The bar is shown whether or not the grade clears it, because an operator
  /// deciding on a B needs to know that a B cannot be verified -- not to
  /// discover it by being refused after they have read the evidence. The server
  /// supplied both the bar and the verdict; nothing here recomputes either.
  Widget _grade(AdminCompetency competency) {
    final summary = competency.thresholdSummary;
    if (summary == null) {
      return const AdminRowNote(
        'No grading scale loaded for this university, so nothing can be '
        'verified here.',
        icon: Icons.info_outline,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        adminCell(summary),
        AdminRowNote(
          competency.meetsThreshold
              ? 'Clears the bar.'
              : 'Below the bar: verifying this will be refused.',
          icon: competency.meetsThreshold
              ? Icons.check_circle_outline
              : Icons.error_outline,
        ),
      ],
    );
  }

  /// Why the last review refused this, when it did.
  ///
  /// The same string the tutor was given. An operator about to refuse again
  /// needs to know what the tutor has already been told, or they will tell them
  /// something different twice.
  Widget _reason(AdminCompetency competency) {
    final reason = competency.rejectionReason;
    if (reason == null) {
      return adminCell(competency.verifiedAt == null ? '—' : 'Verified');
    }
    return AdminRowNote(reason, icon: Icons.block_outlined);
  }

  List<Widget> _actions(AdminCompetency competency, VoidCallback refresh) {
    if (!competency.status.isReviewable) return const <Widget>[];
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

  Future<void> _reject(AdminCompetency competency, VoidCallback refresh) async {
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
    required Future<void> Function(CompetencyReviewController repository)
    action,
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
