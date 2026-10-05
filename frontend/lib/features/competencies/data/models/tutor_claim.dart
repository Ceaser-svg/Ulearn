import 'package:flutter/foundation.dart';
import 'package:peerpass/core/models/json_decimal.dart';

/// Where a tutor's proof has got to, as the API names the states.
///
/// A claim is not competence until an operator has verified it, so this is the
/// one enum in the client a tutor waits on. Parsed leniently for the reason
/// `UserProfile` drops a role it does not recognise: an unrecognised state must
/// render as its own word with no action attached, not crash the applications
/// list or be coerced into "pending".
enum TutorClaimStatus {
  pending('pending'),
  verified('verified'),
  rejected('rejected');

  TutorClaimStatus(this.wireValue);

  /// The value the API uses on the wire.
  ///
  /// Held separately from [name] so renaming the Dart case cannot silently
  /// change what the client reads.
  final String wireValue;

  /// How the state is labelled to the tutor who submitted it.
  ///
  /// A phrase rather than a bare token, because this is the text a tutor reads
  /// to decide what to do next.
  String get label => switch (this) {
    pending => 'Awaiting review',
    verified => 'Verified',
    rejected => 'Not accepted',
  };

  /// The state parsed from a wire value, or null when it is not one we know.
  static TutorClaimStatus? fromWire(String? value) {
    for (final status in TutorClaimStatus.values) {
      if (status.wireValue == value) return status;
    }
    return null;
  }
}

/// One proof a tutor submitted for one course unit, as the API reports it.
///
/// A wire DTO and nothing more. Whether the grade clears the bar is the API's
/// [meetsThreshold]; whether a rejection is fair is nobody's business on this
/// side of the wire. What this type carries is what a tutor needs in order to
/// know where they stand and, if it was refused, what to change.
@immutable
class TutorClaim {
  const TutorClaim({
    required this.id,
    required this.courseUnitId,
    required this.courseUnitCode,
    required this.courseUnitName,
    required this.gradeId,
    required this.gradeLabel,
    required this.statusWire,
    required this.gradePoints,
    required this.meetsThreshold,
    required this.createdAt,
    this.status,
    this.verifiedAt,
    this.rejectionReason,
    this.evidenceReference,
  });

  /// Reads the wire form.
  ///
  /// The tolerance rule is the one `SessionModel` uses: a field whose absence has
  /// one obvious neutral reading is defaulted, and a field a screen cannot render
  /// without is a [FormatException]. `grade_points` in particular is a JSON
  /// *string* -- a `numeric(6,2)` Decimal, which FastAPI serialises that way so
  /// the value is not rounded on the way to a client that only displays it.
  /// Reading it as a number is what broke tutor registration once already; the
  /// reader is in `core/models/json_decimal.dart` and the contract is pinned by
  /// `backend/tests/test_academic_wire_shape.py`.
  factory TutorClaim.fromJson(Map<String, dynamic> json) {
    final id = _readRequiredId(json, 'id');
    final courseUnitId = _readRequiredId(json, 'course_unit_id');
    final gradeId = _readRequiredId(json, 'grade_id');
    final courseUnitCode = json['course_unit_code'];
    final courseUnitName = json['course_unit_name'];
    final gradeLabel = json['grade_label'];
    final statusWire = json['status'];
    final createdAt = json['created_at'];

    if (id == null ||
        courseUnitId == null ||
        gradeId == null ||
        courseUnitCode is! String ||
        courseUnitName is! String ||
        gradeLabel is! String ||
        statusWire is! String ||
        createdAt is! String) {
      throw const FormatException(
        'a tutor claim was missing a field the applications screen needs',
      );
    }

    return TutorClaim(
      id: id,
      courseUnitId: courseUnitId,
      courseUnitCode: courseUnitCode,
      courseUnitName: courseUnitName,
      gradeId: gradeId,
      gradeLabel: gradeLabel,
      statusWire: statusWire,
      status: TutorClaimStatus.fromWire(statusWire),
      gradePoints: readRequiredDecimal(json, 'grade_points'),
      meetsThreshold: json['meets_threshold'] == true,
      createdAt: DateTime.parse(createdAt),
      verifiedAt: _readDateTime(json, 'verified_at'),
      // Not defaulted to an empty string. An absent reason and a reason that
      // was never given are the same thing on the wire, and the screen treats
      // null as "nothing was recorded" rather than showing an empty quotation.
      rejectionReason: _readString(json, 'rejection_reason'),
      evidenceReference: _readString(json, 'evidence_reference'),
    );
  }

  final String id;

  /// The unit's public id. Kept because the client identifies the unit by it.
  final String courseUnitId;

  /// The unit's code, as the catalogue spells it.
  final String courseUnitCode;

  /// The unit's title.
  final String courseUnitName;

  final String gradeId;

  /// The grade as the catalogue names it -- "A", "B+" -- not "4.50".
  final String gradeLabel;

  /// The status exactly as the API spelled it.
  ///
  /// Kept beside the parsed [status] so an unfamiliar state is shown verbatim
  /// rather than as a blank.
  final String statusWire;

  /// The parsed status, or null when the API named one this client predates.
  final TutorClaimStatus? status;

  /// The grade's value on the university's scale.
  final double gradePoints;

  /// Whether the API says this claim counts.
  ///
  /// False while a claim is pending or rejected whatever the grade is: this is
  /// verified eligibility, not the grade's arithmetic.
  final bool meetsThreshold;

  /// When the claim was decided, if it has been.
  final DateTime? verifiedAt;

  /// Why the claim was refused, if it was.
  ///
  /// The only thing that makes a refusal actionable, so it is carried through
  /// rather than reduced to a status the tutor has to interpret alone.
  final String? rejectionReason;

  /// Where the tutor said their evidence lives.
  final String? evidenceReference;

  final DateTime createdAt;

  /// The unit as the applications screen shows it.
  String get courseUnitLabel => '$courseUnitCode · $courseUnitName';

  /// The status as a tutor reads it.
  String get statusLabel => status?.label ?? statusWire;

  /// Whether this claim is still with an operator.
  bool get isPending => status == TutorClaimStatus.pending;

  /// Whether the claim was refused, and whether a reason came with it.
  ///
  /// Split because the two need different words on screen: a refusal with no
  /// recorded reason is a gap in the review, and saying "no reason was given"
  /// is more honest to the tutor than showing an empty space where the reason
  /// should be.
  bool get isRejected => status == TutorClaimStatus.rejected;

  bool get hasRejectionReason =>
      rejectionReason != null && rejectionReason!.trim().isNotEmpty;
}

String? _readRequiredId(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) return null;
  return value;
}

String? _readString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _readDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
