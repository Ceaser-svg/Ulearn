import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';
import 'package:peerpass/features/competencies/data/repositories/competencies_repository.dart';

/// The tutor's own proofs, as a list the applications screen renders.
///
/// Automatic retry is off (`retry: null`) for the reason it is off everywhere
/// else in this app: the screen supplies a retry button, and a provider that
/// silently re-requests ten times turns one lost connection into a spinner that
/// never resolves and a user with nothing to press.
///
/// Throws unless overridden in `ProviderScope`., so leaving the composition root
/// out of a test fails immediately and by name rather than degrading to an empty
/// list that looks like "you have not applied yet".
final myClaimsProvider = FutureProvider<List<TutorClaim>>(
  (ref) => ref.read(competenciesRepositoryProvider).myClaims(),
  retry: (retryCount, error) => null,
);

/// The repository the applications screen and the submission form share.
final competenciesRepositoryProvider = Provider<CompetenciesRepository>(
  (ref) => throw UnimplementedError(
    'competenciesRepositoryProvider must be overridden in ProviderScope.',
  ),
);

/// Submits proof and reports whether it worked, for the submission form.
///
/// A [Provider] rather than a [Notifier], because it exposes no value of
/// its own. The screen owns the message, because the
/// message is a decision about wording that belongs where it is read.
final submitClaimProvider = Provider<SubmitClaimController>(
  SubmitClaimController.new,
);

class SubmitClaimController {
  const SubmitClaimController(this._ref);

  final Ref _ref;

  CompetenciesRepository get _repository =>
      _ref.read(competenciesRepositoryProvider);

  /// Submits, and returns null on success or the [Failure] that stopped it.
  ///
  /// The repository has already turned transport and problem-document faults
  /// into a [Failure] carrying a message a tutor can read, so nothing here
  /// inspects an exception.
  Future<Failure?> submit({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  }) async {
    try {
      await _repository.submitClaim(
        courseUnitId: courseUnitId,
        gradeId: gradeId,
        source: source,
        evidenceReference: evidenceReference,
        notes: notes,
      );
      return null;
    } on Failure catch (failure) {
      return failure;
    }
  }
}
