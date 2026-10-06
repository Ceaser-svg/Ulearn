import 'package:flutter/foundation.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';

/// A tutor competency awaiting or completing review, as
/// `/v1/admin/competencies` describes it.
///
/// The review fields staff need, without the submitted evidence document
/// itself: the console shows the reference an auditor can follow up on, not
/// the document it points at.
///
/// The grade arrives as both a label and a number, alongside the bar that
/// number has to clear. `meetsThreshold` is the server's own answer to the
/// question an operator is deciding, so the console never recomputes it: a
/// client-side comparison would be a second, disagreeable statement of MUST
/// invariant 2.
///
/// Immutable and equality-compared, like `AdminPage` beside it, because a
/// refreshed row replaces its predecessor and the pager and any `==` over a
/// refreshed list have to be able to tell that the data changed.
@immutable
class AdminCompetency {
  const AdminCompetency({
    required this.id,
    required this.email,
    required this.name,
    required this.unit,
    required this.gradeLabel,
    required this.gradePoints,
    required this.meetsThreshold,
    required this.status,
    required this.rawStatus,
    required this.evidence,
    required this.submittedAt,
    this.competencyMinPoints,
    this.rejectionReason,
    this.verifiedAt,
  });

  factory AdminCompetency.fromJson(Map<String, dynamic> json) {
    // Kept verbatim as well as parsed, because an unrecognised status still has
    // to be readable. Showing "Unknown" for a status the server named is a
    // worse answer than showing what it actually said.
    final rawStatus = json['status'] as String;
    return AdminCompetency(
      id: json['id'] as String,
      email: json['user_email'] as String,
      name: json['user_name'] as String?,
      unit: '${json['course_unit_code']} - ${json['course_unit_name']}',
      gradeLabel: json['grade_label'] as String,
      gradePoints: json['grade_points'] as String,
      competencyMinPoints: json['competency_min_points'] as String?,
      meetsThreshold: json['meets_threshold'] as bool? ?? false,
      status: CompetencyStatus.parse(rawStatus),
      rawStatus: rawStatus,
      evidence: json['evidence_reference'] as String?,
      rejectionReason: json['rejection_reason'] as String?,
      submittedAt: DateTime.parse(json['created_at'] as String),
      verifiedAt: json['verified_at'] == null
          ? null
          : DateTime.parse(json['verified_at'] as String),
    );
  }

  final String id;
  final String email;
  final String? name;
  final String unit;

  /// What a marker recognises, e.g. `B+`.
  final String gradeLabel;

  /// The same grade as a number on the unit's own scale.
  final String gradePoints;

  /// The lowest grade that makes a tutor eligible in this unit's university, in
  /// the same points as [gradePoints]. Null when that university has no grading
  /// scale loaded, which is a normal state and not a fault.
  final String? competencyMinPoints;

  /// Whether [gradePoints] clears [competencyMinPoints], as the server computes
  /// it. False when there is no scale, because verification refuses in that
  /// state and `true` would promise a decision the server will not make.
  final bool meetsThreshold;

  final CompetencyStatus status;

  /// [status] as the API spelled it, for display when [status] is
  /// [CompetencyStatus.unknown].
  final String rawStatus;

  final String? evidence;

  /// Why the last review refused this, if it did. The same string the tutor was
  /// given, which is the point: an operator deciding whether to refuse again
  /// needs to know what the tutor already knows.
  final String? rejectionReason;

  /// When the tutor submitted this. The queue is ordered by it, and it is how
  /// long they have been waiting.
  final DateTime submittedAt;

  /// When it was verified, which is null for every other status.
  final DateTime? verifiedAt;

  /// What to show for this row's status.
  String get statusLabel => status.isKnown ? status.label : rawStatus;

  /// The grade and the bar, in the form the API's own refusal message uses.
  ///
  /// Null when there is no bar to compare against, because "A of nothing" is
  /// not a comparison.
  String? get thresholdSummary {
    final minimum = competencyMinPoints;
    if (minimum == null) return null;
    return '$gradeLabel ($gradePoints) against a $minimum bar';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdminCompetency &&
          other.id == id &&
          other.status == status &&
          other.rawStatus == rawStatus &&
          other.gradeLabel == gradeLabel &&
          other.gradePoints == gradePoints &&
          other.meetsThreshold == meetsThreshold &&
          other.rejectionReason == rejectionReason;

  @override
  int get hashCode => Object.hash(
    id,
    status,
    rawStatus,
    gradeLabel,
    gradePoints,
    meetsThreshold,
    rejectionReason,
  );
}
