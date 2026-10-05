import 'package:flutter/foundation.dart';
import 'package:peerpass/core/models/json_decimal.dart';
import 'package:peerpass/core/models/tutor_summary.dart';

/// Why a tutor was considered for a course unit and then ruled out.
///
/// A code rather than prose, because the client branches on it and the API is
/// free to reword an explanation without breaking a screen. Every case here is a
/// documented `MATCH_EXCLUSION_REASONS` member; a code that arrives from a newer
/// server than this client parses to null and is reported as "we could not say",
/// which is the only honest thing to say about a rule this build has never seen.
///
/// What each code *means* for eligibility is the API's rule and is deliberately
/// not re-derived here. What is here is how to tell a student about it.
enum MatchExclusionReason {
  belowThreshold('below_threshold'),
  sameUniversityOnly('same_university_only'),
  suspended('suspended'),
  unverified('unverified'),
  notTheTutor('not_the_tutor');

  MatchExclusionReason(this.wireValue);

  /// The value the API uses on the wire.
  final String wireValue;

  /// Why this tutor was passed over, as a clause that reads after "because".
  ///
  /// A clause and not a whole sentence, because the screen counts the tutors and
  /// the reason together -- "2 tutors were not proposed because their verified
  /// grade is below the bar for this unit" -- and a sentence here would have to
  /// be taken apart to be reused. Kept in the second person about the tutor and
  /// the third person about the student, since a student reading about a
  /// stranger needs to know which is which.
  String get explanation => switch (this) {
    belowThreshold => 'their verified grade is below what this unit asks for',
    sameUniversityOnly => 'they teach at another university',
    suspended => 'their tutoring access has been suspended',
    unverified => 'the grade they claimed has not been checked by anyone yet',
    notTheTutor => 'they have no tutor profile for the platform to rank',
  };

  /// The reason parsed from a wire code, or null when unrecognised.
  static MatchExclusionReason? fromWire(String? value) {
    for (final reason in MatchExclusionReason.values) {
      if (reason.wireValue == value) return reason;
    }
    return null;
  }
}

/// A tutor the engine looked at and did not propose.
@immutable
class MatchExclusion {
  const MatchExclusion({
    required this.tutorId,
    required this.reasonWire,
    this.reason,
  });

  /// Reads one exclusion.
  ///
  /// A missing id is a [FormatException]: an exclusion with nothing to exclude
  /// is not a sentence a screen can build, and the repository reports the
  /// response as unreadable rather than the screen showing a blank bullet.
  factory MatchExclusion.fromJson(Map<String, dynamic> json) {
    final tutorId = json['tutor_id'];
    final reasonWire = json['reason'];
    if (tutorId is! String ||
        tutorId.isEmpty ||
        reasonWire is! String ||
        reasonWire.isEmpty) {
      throw const FormatException('exclusion was missing a tutor or a reason');
    }

    return MatchExclusion(
      tutorId: tutorId,
      reasonWire: reasonWire,
      reason: MatchExclusionReason.fromWire(reasonWire),
    );
  }

  /// The tutor's public id.
  ///
  /// An id and not a name: the API excludes a tutor without saying who they are,
  /// so the client cannot name them and does not invent a name. The screen says
  /// how many tutors it left out and why.
  final String tutorId;

  /// The code exactly as the API spelled it.
  final String reasonWire;

  /// The parsed reason, or null when the API used a code this client predates.
  final MatchExclusionReason? reason;

  /// Why this tutor was passed over, or the honest answer when it is unknown.
  String get explanation =>
      reason?.explanation ?? 'we could not say why this tutor was left out';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MatchExclusion &&
          other.tutorId == tutorId &&
          other.reasonWire == reasonWire;

  @override
  int get hashCode => Object.hash(tutorId, reasonWire);

  @override
  String toString() => 'MatchExclusion($tutorId, $reasonWire)';
}

/// An eligible tutor, with the evidence behind the ranking.
@immutable
class MatchCandidate {
  const MatchCandidate({
    required this.tutor,
    required this.courseUnitId,
    required this.meetsThreshold,
    required this.score,
    this.competencyGradePoints,
  });

  /// Reads one candidate.
  ///
  /// `competency_grade_points` is read as the string-decimal the wire carries and
  /// kept nullable: the engine only proposes tutors who passed the bar, so a
  /// candidate with no grade points on the wire is not one a screen can say
  /// anything quantitative about, and refusing the whole response over it would
  /// hide a list of tutors the student asked for.
  factory MatchCandidate.fromJson(Map<String, dynamic> json) {
    final tutor = json['tutor'];
    final courseUnitId = json['course_unit_id'];
    final score = json['score'];

    if (tutor is! Map<String, dynamic> ||
        courseUnitId is! String ||
        score is! num) {
      throw const FormatException('candidate was missing its tutor or score');
    }

    return MatchCandidate(
      tutor: TutorSummary.fromJson(tutor),
      courseUnitId: courseUnitId,
      competencyGradePoints: readDecimal(json['competency_grade_points']),
      meetsThreshold: switch (json['meets_threshold']) {
        final bool meets => meets,
        // The API documents a boolean here. Defaulting a non-boolean to false
        // would assert the tutor failed the bar, which is the opposite of what a
        // response that simply left the field out means.
        _ => true,
      },
      score: score.toDouble(),
    );
  }

  final TutorSummary tutor;

  /// The unit this candidate was proposed for.
  ///
  /// Not necessarily the unit that was asked about: when the search widened, this
  /// is the tutor's own unit, which is why the screen says so.
  final String courseUnitId;

  /// The grade the API holds for this tutor in this unit, or null if it sent
  /// none.
  ///
  /// Grade *points* on the university's own scale, so it is shown as a labelled
  /// number and never as a percentage or a grade letter: this client cannot know
  /// which scale a university publishes, and guessing one would be a claim the
  /// server never made.
  final double? competencyGradePoints;

  /// Whether the API considers this grade good enough for the unit.
  ///
  /// Always true for a candidate the API chose to propose, so no screen renders
  /// it. Kept because it is part of the wire contract and a test asserts the
  /// response is read whole.
  final bool meetsThreshold;

  /// The engine's ranking score.
  ///
  /// Kept, and never displayed: the API documents it as relative to one request,
  /// so a number on screen would invite a comparison across two searches that
  /// the number cannot support.
  final double score;

  /// The grade points as a label, or the honest answer when there are none.
  String get gradeLabel => competencyGradePoints == null
      ? 'Grade not on record'
      : 'Grade points ${competencyGradePoints!.toStringAsFixed(1)}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MatchCandidate &&
          other.tutor == tutor &&
          other.courseUnitId == courseUnitId &&
          other.competencyGradePoints == competencyGradePoints &&
          other.meetsThreshold == meetsThreshold &&
          other.score == score;

  @override
  int get hashCode => Object.hash(
    tutor,
    courseUnitId,
    competencyGradePoints,
    meetsThreshold,
    score,
  );

  @override
  String toString() => 'MatchCandidate(${tutor.userId}, $courseUnitId)';
}

/// The outcome of one matching call.
@immutable
class MatchResult {
  const MatchResult({
    required this.courseUnitId,
    required this.widened,
    required this.candidates,
    required this.exclusions,
    required this.noEligibleTutors,
    required this.generatedAt,
    this.requestId,
  });

  /// Reads a match response.
  ///
  /// `candidates` and `exclusions` default to empty, because an absent list and
  /// an empty one mean the same thing here and a missing `candidates` is not a
  /// reason to refuse a response that is otherwise readable. `course_unit_id`
  /// and `generated_at` are not defaulted: without them a screen could not say
  /// which unit it is looking at, or when the answer was true.
  factory MatchResult.fromJson(Map<String, dynamic> json) {
    final courseUnitId = json['course_unit_id'];
    final generatedAt = json['generated_at'];
    if (courseUnitId is! String || generatedAt is! String) {
      throw const FormatException(
        'match response was missing the unit or the time',
      );
    }

    final requestId = json['request_id'];

    return MatchResult(
      // Null for the unit-only query, which is the route this client calls: an
      // id naming no help request would be a link the client could follow to a
      // 404, so it is kept as "not a request" rather than as a string.
      requestId: requestId is String && requestId.isNotEmpty ? requestId : null,
      courseUnitId: courseUnitId,
      widened: switch (json['widened']) {
        final bool widened => widened,
        // Absent means the API did not widen, which is the documented default of
        // `widen_to_subject`.
        _ => false,
      },
      candidates: [
        for (final row in _rows(json['candidates']))
          MatchCandidate.fromJson(row),
      ],
      exclusions: [
        for (final row in _rows(json['exclusions']))
          MatchExclusion.fromJson(row),
      ],
      noEligibleTutors: switch (json['no_eligible_tutors']) {
        final bool none => none,
        // The field exists precisely so a blank result can say "nobody is
        // eligible" rather than looking like a loading failure. Absent, this client
        // falls back to the candidate list rather than asserting nobody was found.
        _ => false,
      },
      generatedAt: DateTime.parse(generatedAt),
    );
  }

  /// The help request these candidates answer, when the query was made for one.
  ///
  /// Always null for `POST /v1/matching/suggestions`, which is the route this
  /// client calls. Held because a client must only open the request id it sent.
  final String? requestId;

  /// The unit that was asked about.
  final String courseUnitId;

  /// Whether the exact unit had no eligible tutor and the subject was searched
  /// instead.
  ///
  /// The single most important field on this response for the student: when it is
  /// true, none of these tutors teaches the unit they asked about, and a screen
  /// that shows the list without saying so has told them something false.
  final bool widened;

  final List<MatchCandidate> candidates;

  /// Tutors who were considered and ruled out.
  ///
  /// The answer to "why is my tutor not showing up", and the reason the screen
  /// reads them rather than discarding them.
  final List<MatchExclusion> exclusions;

  /// Whether the engine found nobody at all.
  ///
  /// Sent explicitly rather than left to be inferred from an empty list, because
  /// "nobody is eligible" is a fact about the platform and an empty list is also
  /// what a client that has not finished asking looks like.
  final bool noEligibleTutors;

  final DateTime generatedAt;

  /// How many tutors the engine passed over, in one sentence's worth of numbers.
  int get excludedCount => exclusions.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MatchResult &&
          other.requestId == requestId &&
          other.courseUnitId == courseUnitId &&
          other.widened == widened &&
          other.noEligibleTutors == noEligibleTutors &&
          other.generatedAt == generatedAt &&
          listEquals(other.candidates, candidates) &&
          listEquals(other.exclusions, exclusions);

  @override
  int get hashCode => Object.hash(
    requestId,
    courseUnitId,
    widened,
    candidates.length,
    exclusions.length,
    noEligibleTutors,
    generatedAt,
  );

  @override
  String toString() =>
      'MatchResult($courseUnitId, widened: $widened, '
      '${candidates.length} candidates)';
}

List<Map<String, dynamic>> _rows(Object? value) {
  if (value is! List) return const [];
  return [
    for (final row in value)
      if (row is Map<String, dynamic>) row,
  ];
}
