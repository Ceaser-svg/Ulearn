import 'package:flutter/foundation.dart';
import 'package:peerpass/core/models/json_decimal.dart';
import 'package:peerpass/core/models/tutor_standing.dart';

/// The tutor fields a student is allowed to see.
///
/// Lives in `core/models/` rather than in the feature that reads it most
/// because two features read it: the tutor rail renders a `TutorProfileSummary`
/// and matching renders one per candidate. AGENTS.md puts a shared type several
/// features need in `core/models/`, and the alternative -- matching importing
/// the tutors feature's model -- is the cross-feature import the dependency
/// rules forbid.
///
/// A wire DTO and nothing more. What standing *means* for eligibility, what a
/// grade has to be to be a candidate, and who gets promoted are all API rules;
/// this type parses what the API said and formats it.
@immutable
class TutorSummary {
  const TutorSummary({
    required this.userId,
    required this.fullName,
    required this.standingWire,
    required this.completedSessions,
    this.standing,
    this.averageRating,
  });

  /// Reads the student-facing tutor shape.
  ///
  /// The three fields without an obvious neutral reading -- the id, the name,
  /// and the completed-session count -- are a [FormatException] when absent,
  /// because a card with no name and a card with no name *yet* look identical
  /// and only one of them is a server fault. `average_rating` is nullable
  /// because null is a real value here: the API sends it for a tutor with no
  /// ratings, and a client that read that as zero would call them badly rated.
  ///
  /// A [FormatException] here becomes a `ServerFailure` in the repository, so
  /// it reaches a screen as a message rather than as a type name.
  factory TutorSummary.fromJson(Map<String, dynamic> json) {
    final userId = _readString(json, 'user_id');
    final fullName = _readString(json, 'full_name');
    final standingWire = _readString(json, 'standing');
    final completedSessions = json['completed_sessions'];

    if (userId == null ||
        fullName == null ||
        standingWire == null ||
        completedSessions is! num) {
      throw const FormatException(
        'tutor response was missing a required field',
      );
    }

    return TutorSummary(
      userId: userId,
      fullName: fullName,
      standingWire: standingWire,
      standing: TutorStanding.fromWire(standingWire),
      averageRating: readDecimal(json['average_rating']),
      completedSessions: completedSessions.toInt(),
    );
  }

  final String userId;

  /// The name a student sees.
  ///
  /// The API falls back to the account's email address when there is no name on
  /// file, so this is never blank in practice and the client does not invent a
  /// placeholder for it.
  final String fullName;

  /// The standing exactly as the API spelled it.
  ///
  /// Kept beside the parsed [standing] so an unrecognised one can be shown
  /// verbatim rather than as a blank or a guessed label.
  final String standingWire;

  /// The parsed standing, or null when the API named one this client predates.
  final TutorStanding? standing;

  /// The mean score, or null when the tutor has no ratings yet.
  ///
  /// A double, and not the string the wire carries, because the only thing done
  /// with it here is displaying it: every threshold comparison happens
  /// server-side against the `Decimal` before serialisation. See
  /// [readDecimal] for why the wire value is a string.
  final double? averageRating;

  final int completedSessions;

  /// The standing as a student reads it.
  String get standingLabel => standing?.label ?? standingWire;

  /// The average rating as a student reads it.
  ///
  /// "No ratings yet" for a null average rather than a zero, a dash, or a bare
  /// star: a tutor nobody has rated has an absence of evidence, and every one of
  /// those renderings reads as a bad score. One decimal place because that is
  /// the precision the API rounds to, and showing `"4.10"` as the raw wire
  /// string would be showing a serialisation detail.
  String get ratingLabel => averageRating == null
      ? 'No ratings yet'
      : averageRating!.toStringAsFixed(1);

  /// Whether this tutor has at least one rating.
  bool get hasRatings => averageRating != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TutorSummary &&
          other.userId == userId &&
          other.fullName == fullName &&
          other.standingWire == standingWire &&
          other.averageRating == averageRating &&
          other.completedSessions == completedSessions;

  @override
  int get hashCode => Object.hash(
    userId,
    fullName,
    standingWire,
    averageRating,
    completedSessions,
  );

  @override
  String toString() => 'TutorSummary($userId, $standingWire)';
}

/// A string field, treating an empty one as absent.
///
/// A non-string is treated as absent rather than coerced, on the same grounds as
/// the rest of the client: a field that arrives as something else is one this
/// client cannot use, and coercing it would put a number in an id field.
String? _readString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) return null;
  return value.isEmpty ? null : value;
}
