import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';
import 'package:peerpass/features/competencies/data/repositories/competencies_repository.dart';

/// An in-memory [CompetenciesRepository] for tests and previews.
///
/// Refuses a second claim for a unit that already has one, exactly as the API
/// does, so a screen test that submits twice is testing a screen rather than the
/// fake's permissiveness. It deliberately does *not* model the rejection
/// reopening the API allows: a test for that behaviour belongs on the API, and a
/// fake that reopened silently would let a screen assume a rule it does not have.
class FakeCompetenciesRepository implements CompetenciesRepository {
  FakeCompetenciesRepository({List<TutorClaim>? claims})
    : claims = [...?claims];

  /// The claims the screen will read, in the order the endpoint returns them.
  final List<TutorClaim> claims;

  /// Every submission this fake was asked to make, newest last.
  final List<SubmittedClaim> submitted = [];

  /// Set to have the next [myClaims] fail, as a lost connection would.
  Failure? listError;

  /// Set to have the next [submitClaim] fail, as a validation failure would.
  Failure? submitError;

  @override
  Future<List<TutorClaim>> myClaims() async {
    final failure = listError;
    if (failure != null) {
      listError = null;
      throw failure;
    }
    return List.unmodifiable(claims);
  }

  @override
  Future<TutorClaim> submitClaim({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  }) async {
    submitted.add(
      SubmittedClaim(
        courseUnitId: courseUnitId,
        gradeId: gradeId,
        source: source,
        evidenceReference: evidenceReference,
        notes: notes,
      ),
    );

    final failure = submitError;
    if (failure != null) {
      submitError = null;
      throw failure;
    }

    if (claims.any((claim) => claim.courseUnitId == courseUnitId)) {
      throw const ValidationFailure(
        'A competency already exists for this unit.',
        fieldErrors: {'course_unit_id': 'duplicate competency'},
      );
    }

    final created = TutorClaim(
      id: 'claim-for-$courseUnitId',
      courseUnitId: courseUnitId,
      courseUnitCode: 'MAT 221',
      courseUnitName: 'Linear Algebra',
      gradeId: gradeId,
      gradeLabel: 'A',
      statusWire: TutorClaimStatus.pending.wireValue,
      status: TutorClaimStatus.pending,
      gradePoints: 5,
      meetsThreshold: false,
      createdAt: DateTime.utc(2026, 3, 1, 8),
      evidenceReference: evidenceReference,
    );
    claims.insert(0, created);
    return created;
  }
}

/// What a submission was asked for, so a screen test can check the real call.
class SubmittedClaim {
  const SubmittedClaim({
    required this.courseUnitId,
    required this.gradeId,
    required this.source,
    this.evidenceReference,
    this.notes,
  });

  final String courseUnitId;
  final String gradeId;
  final String source;
  final String? evidenceReference;
  final String? notes;
}
