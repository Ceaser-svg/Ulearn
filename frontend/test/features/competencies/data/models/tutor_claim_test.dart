import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';

/// The shape `GET /v1/competencies/me` returns.
Map<String, dynamic> claimJson({
  String id = 'claim-1',
  String status = 'pending',
  String? rejectionReason,
  String? verifiedAt,
  String? evidenceReference = 'Semester 5 transcript',
  Object? gradePoints = '5.00',
  Object? meetsThreshold = false,
  String? courseUnitCode = 'MAT 221',
  String? courseUnitName = 'Linear Algebra',
  String? gradeLabel = 'A',
}) {
  return {
    'id': id,
    'user_id': 'student-1',
    'course_unit_id': 'unit-1',
    'course_unit_code': courseUnitCode,
    'course_unit_name': courseUnitName,
    'grade_id': 'grade-1',
    'grade_label': gradeLabel,
    'status': status,
    'source': 'transcript',
    'grade_points': gradePoints,
    'meets_threshold': meetsThreshold,
    'verified_at': verifiedAt,
    'rejection_reason': rejectionReason,
    'evidence_reference': evidenceReference,
    'created_at': '2026-03-01T08:00:00Z',
  };
}

void main() {
  group('reading a tutor claim', () {
    test('reads the whole documented response', () {
      final claim = TutorClaim.fromJson(
        claimJson(verifiedAt: '2026-03-02T09:00:00Z', meetsThreshold: true),
      );

      expect(claim.id, 'claim-1');
      expect(claim.courseUnitId, 'unit-1');
      expect(claim.courseUnitCode, 'MAT 221');
      expect(claim.courseUnitName, 'Linear Algebra');
      expect(claim.courseUnitLabel, 'MAT 221 · Linear Algebra');
      expect(claim.gradeLabel, 'A');
      expect(claim.status, TutorClaimStatus.pending);
      expect(claim.statusLabel, 'Awaiting review');
      expect(claim.gradePoints, 5.0);
      expect(claim.meetsThreshold, isTrue);
      expect(claim.isPending, isTrue);
      expect(claim.isRejected, isFalse);
    });

    test('reads grade_points as the JSON string the API sends', () {
      // The field is a `numeric(6,2)` Decimal, which FastAPI serialises as a
      // string so the value is not rounded on the way to a client that only
      // displays it. Reading it as a number is what broke tutor registration
      // once; the contract is pinned by
      // `backend/tests/test_academic_wire_shape.py`.
      expect(claimJson()['grade_points'], isA<String>());
      expect(TutorClaim.fromJson(claimJson()).gradePoints, 5.0);
      expect(
        TutorClaim.fromJson(claimJson(gradePoints: '4.10')).gradePoints,
        4.1,
      );
      // A JSON number is still accepted: the same reader is used where the field
      // is genuinely numeric, and a client that broke on one would turn a
      // forward-compatible server change into a dead screen.
      expect(TutorClaim.fromJson(claimJson(gradePoints: 4.5)).gradePoints, 4.5);
    });

    test('an unreadable grade is refused rather than read as zero', () {
      // Zero is a real grade on this scale and fails the threshold. Defaulting
      // to it would let a claim look like a D rather than an unreadable body.
      expect(
        () => TutorClaim.fromJson(claimJson(gradePoints: null)),
        throwsFormatException,
      );
      expect(
        () => TutorClaim.fromJson(claimJson(gradePoints: 'not a number')),
        throwsFormatException,
      );
    });

    test('a rejected claim carries the reason it was refused', () {
      final claim = TutorClaim.fromJson(
        claimJson(
          status: 'rejected',
          rejectionReason: 'The transcript reference does not name the course.',
        ),
      );

      expect(claim.status, TutorClaimStatus.rejected);
      expect(claim.statusLabel, 'Not accepted');
      expect(claim.isRejected, isTrue);
      expect(
        claim.rejectionReason,
        'The transcript reference does not name the course.',
      );
      expect(claim.hasRejectionReason, isTrue);
    });

    test('a rejection with no reason is distinguishable from one with it', () {
      // The screen says something different in each case, so the two must not
      // both collapse to an empty string.
      expect(
        TutorClaim.fromJson(claimJson(status: 'rejected')).hasRejectionReason,
        isFalse,
      );
      expect(
        TutorClaim.fromJson(
          claimJson(status: 'rejected', rejectionReason: '   '),
        ).hasRejectionReason,
        isFalse,
      );
      expect(
        TutorClaim.fromJson(claimJson(status: 'rejected', rejectionReason: ''))
            .hasRejectionReason,
        isFalse,
      );
    });

    test('a pending claim reports the threshold as not met', () {
      // `meets_threshold` is verified eligibility, not the grade's arithmetic: a
      // claim no operator has approved is not eligible however good the grade.
      // Pinned so a later change to make it true has to be deliberate.
      expect(TutorClaim.fromJson(claimJson()).meetsThreshold, isFalse);
      expect(
        TutorClaim.fromJson(claimJson(status: 'rejected')).meetsThreshold,
        isFalse,
      );
    });

    test('an unfamiliar status is shown as the API spelled it', () {
      // The same tolerance as `UserProfile`: a state this client predates must
      // render as an unfamiliar label with no action attached, not crash the
      // list and not be coerced into `pending`.
      final claim = TutorClaim.fromJson(claimJson(status: 'expired'));

      expect(claim.status, isNull);
      expect(claim.statusWire, 'expired');
      expect(claim.statusLabel, 'expired');
      expect(claim.isPending, isFalse);
      expect(claim.isRejected, isFalse);
    });

    test('every field the screen reads is required', () {
      for (final key in [
        'id',
        'course_unit_id',
        'course_unit_code',
        'course_unit_name',
        'grade_id',
        'grade_label',
        'status',
        'grade_points',
        'created_at',
      ]) {
        final body = claimJson()..remove(key);
        expect(
          () => TutorClaim.fromJson(body),
          throwsFormatException,
          reason: 'a claim without $key cannot be rendered and must be refused',
        );
      }
    });
  });

  group('the status enum', () {
    test('parses every state the API names', () {
      expect(TutorClaimStatus.fromWire('pending'), TutorClaimStatus.pending);
      expect(TutorClaimStatus.fromWire('verified'), TutorClaimStatus.verified);
      expect(TutorClaimStatus.fromWire('rejected'), TutorClaimStatus.rejected);
    });

    test('returns null for a state it does not know, and never throws', () {
      expect(TutorClaimStatus.fromWire('withdrawn'), isNull);
      expect(TutorClaimStatus.fromWire(null), isNull);
      expect(TutorClaimStatus.fromWire(''), isNull);
    });
  });
}
