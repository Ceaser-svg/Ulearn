// The wire shape of the review queue, and what the console does with a status
// its build has never heard of.
//
// The unknown-status case is the one that matters here. The server owns the
// rule and a newer API may legitimately have added a state; a client that
// crashes or blanks the field on an unrecognised value would turn a backend
// deploy into "the console is broken" for every operator on shift.
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';

/// A competency row as the API serves one.
Map<String, dynamic> competencyJson({
  String status = 'pending',
  String gradeLabel = 'B+',
  String gradePoints = '4.30',
  Object? competencyMinPoints = '4.50',
  bool? meetsThreshold = true,
  Object? rejectionReason,
  Object? verifiedAt,
}) => <String, dynamic>{
  'id': 'competency-1',
  'user_id': 'user-1',
  'user_email': 'tutor@peerpass.test',
  'user_name': 'Grace Tutor',
  'course_unit_id': 'unit-1',
  'course_unit_code': 'CS301',
  'course_unit_name': 'Algorithms',
  'grade_label': gradeLabel,
  'grade_points': gradePoints,
  'competency_min_points': competencyMinPoints,
  'meets_threshold': meetsThreshold,
  'status': status,
  'source': 'transcript',
  'evidence_reference': 'transcript-2026.pdf',
  'rejection_reason': rejectionReason,
  'created_at': '2026-01-02T10:30:00Z',
  'verified_at': verifiedAt,
};

void main() {
  group('a competency row', () {
    test('carries the label the bar and the verdict together', () {
      final competency = AdminCompetency.fromJson(competencyJson());

      // The label, because `4.30` is not what a marker recognises.
      expect(competency.gradeLabel, 'B+');
      expect(competency.gradePoints, '4.30');
      // The bar and the server's own verdict on it, so the operator is not
      // discovering the gate by being refused.
      expect(competency.competencyMinPoints, '4.50');
      expect(competency.meetsThreshold, isTrue);
      expect(competency.thresholdSummary, 'B+ (4.30) against a 4.50 bar');
    });

    test('reports a grade under the bar as not clearing it', () {
      final competency = AdminCompetency.fromJson(
        competencyJson(
          gradeLabel: 'B',
          gradePoints: '4.00',
          meetsThreshold: false,
        ),
      );

      expect(competency.meetsThreshold, isFalse);
      expect(competency.thresholdSummary, 'B (4.00) against a 4.50 bar');
    });

    test('has no bar to compare against when the scale is missing', () {
      final competency = AdminCompetency.fromJson(
        competencyJson(competencyMinPoints: null),
      );

      // Null rather than a comparison: "A of nothing" is not a comparison, and
      // the screen says so instead of rendering a ratio against no bar.
      expect(competency.competencyMinPoints, isNull);
      expect(competency.thresholdSummary, isNull);
    });

    test('treats a missing threshold flag as not meeting the bar', () {
      // False rather than `true`: the server is the authority on MUST invariant
      // 2, and if it did not say the gate is cleared then the console must not
      // claim it is. An optimistic default would let an operator read a row as
      // approvable on the strength of a field that never arrived.
      final competency = AdminCompetency.fromJson(
        competencyJson(meetsThreshold: null),
      );

      expect(competency.meetsThreshold, isFalse);
    });

    test('carries the reason the last review refused it', () {
      final competency = AdminCompetency.fromJson(
        competencyJson(
          status: 'rejected',
          rejectionReason: 'The transcript page is missing.',
        ),
      );

      expect(competency.rejectionReason, 'The transcript page is missing.');
      expect(competency.status, CompetencyStatus.rejected);
    });

    test('carries when it was submitted and when it was verified', () {
      final pending = AdminCompetency.fromJson(competencyJson());
      expect(pending.submittedAt, DateTime.parse('2026-01-02T10:30:00Z'));
      expect(pending.verifiedAt, isNull);

      final verified = AdminCompetency.fromJson(
        competencyJson(status: 'verified', verifiedAt: '2026-01-03T08:00:00Z'),
      );
      expect(verified.verifiedAt, DateTime.parse('2026-01-03T08:00:00Z'));
    });
  });

  group('the status', () {
    test('parses every status this build knows', () {
      expect(CompetencyStatus.parse('pending'), CompetencyStatus.pending);
      expect(CompetencyStatus.parse('verified'), CompetencyStatus.verified);
      expect(CompetencyStatus.parse('rejected'), CompetencyStatus.rejected);
    });

    test('keeps showing a status it does not know', () {
      final competency = AdminCompetency.fromJson(
        competencyJson(status: 'awaiting_registry'),
      );

      // Not a crash and not a blank cell: the value is preserved verbatim so an
      // operator can report what the server actually said.
      expect(competency.status, CompetencyStatus.unknown);
      expect(competency.status.isKnown, isFalse);
      expect(competency.statusLabel, 'awaiting_registry');
      // And a status this build cannot name is not offered as a reviewable one:
      // the server owns the transition and this client does not know what
      // allows it.
      expect(competency.status.isReviewable, isFalse);
    });

    test('offers review actions only while a competency is pending', () {
      expect(CompetencyStatus.pending.isReviewable, isTrue);
      expect(CompetencyStatus.verified.isReviewable, isFalse);
      expect(CompetencyStatus.rejected.isReviewable, isFalse);
      expect(CompetencyStatus.unknown.isReviewable, isFalse);
    });

    test('filters by the three the server owns, waiting first', () {
      // The order an operator works the queue in: what is waiting, then what was
      // decided each way.
      expect(CompetencyStatus.filterable, <CompetencyStatus>[
        CompetencyStatus.pending,
        CompetencyStatus.rejected,
        CompetencyStatus.verified,
      ]);
    });
  });

  group('an audit row', () {
    test('names its actor', () {
      final event = AuditEvent.fromJson(<String, dynamic>{
        'id': 'event-1',
        'actor_id': 'actor-1',
        'actor_email': 'operator@peerpass.test',
        'actor_name': 'Grace Operator',
        'action': 'admin.competencies.list',
        'target_type': 'competency',
        'target_public_id': 'competency-1',
        'context': <String, dynamic>{'status': 'pending'},
        'created_at': '2026-01-02T10:30:00Z',
      });

      expect(event.actorLabel, 'Grace Operator');
      // And the identifier survives, so an auditor can still join on it.
      expect(event.actorId, 'actor-1');
    });

    test('falls back to the email when the operator has no name', () {
      final event = AuditEvent.fromJson(<String, dynamic>{
        'id': 'event-1',
        'actor_id': 'actor-1',
        'actor_email': 'operator@peerpass.test',
        'actor_name': null,
        'action': 'admin.competencies.list',
        'target_type': 'competency',
        'target_public_id': null,
        'context': <String, dynamic>{},
        'created_at': '2026-01-02T10:30:00Z',
      });

      // A staff account registered without a full name is a real state, and a
      // blank actor column would make the log useless for that operator.
      expect(event.actorLabel, 'operator@peerpass.test');
    });
  });

  group('a user row', () {
    test('still parses', () {
      // Present so a change to the model layer cannot quietly break a list that
      // has nothing to do with competencies.
      final user = AdminUser.fromJson(<String, dynamic>{
        'id': 'user-1',
        'email': 'ada@peerpass.test',
        'full_name': 'Ada Lovelace',
        'roles': <String>['student', 'tutor'],
        'university_id': null,
        'faculty_id': null,
        'year_of_study': 2,
        'is_active': true,
        'created_at': '2026-01-01T09:00:00Z',
      });

      expect(user.name, 'Ada Lovelace');
    });
  });
}
