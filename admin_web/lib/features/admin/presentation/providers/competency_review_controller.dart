import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';

/// What a review attempt did, so a screen can report it without knowing why.
enum CompetencyReviewOutcome { verified, rejected, failed }

/// Records competency reviews.
///
/// The console's one write, and the one place a button used to call the API
/// directly. A transport failure is reported as [CompetencyReviewOutcome.failed]
/// rather than thrown, because the operator's next move is the same either
/// way and a thrown exception would only produce a blank screen.
final competencyReviewControllerProvider = Provider<CompetencyReviewController>(
  (ref) => CompetencyReviewController(ref.watch(adminRepositoryProvider)),
);

class CompetencyReviewController {
  const CompetencyReviewController(this._repository);

  final AdminRepository _repository;

  Future<CompetencyReviewOutcome> verify(AdminCompetency competency) =>
      _review(competency, 'verified', CompetencyReviewOutcome.verified);

  Future<CompetencyReviewOutcome> reject(
    AdminCompetency competency,
    String reason,
  ) => _review(
    competency,
    'rejected',
    CompetencyReviewOutcome.rejected,
    reason: reason,
  );

  Future<CompetencyReviewOutcome> _review(
    AdminCompetency competency,
    String status,
    CompetencyReviewOutcome succeeded, {
    String? reason,
  }) async {
    try {
      await _repository.reviewCompetency(competency, status, reason: reason);
    } on DioException {
      return CompetencyReviewOutcome.failed;
    }
    return succeeded;
  }
}
