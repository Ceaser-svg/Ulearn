import 'package:flutter/foundation.dart';
import 'package:peerpass/core/models/user_role.dart';

/// The signed-in user's own record, as the API returns it.
///
/// One model rather than an identity plus a separate profile. The router's
/// guard has to decide whether to send someone to onboarding, and that decision
/// needs the name and university that only the profile carries. Splitting them
/// would mean every caller that wanted a greeting also had to hold the second
/// object, and the two would be free to disagree about who the user is.
@immutable
class UserProfile {
  const UserProfile({
    required this.publicId,
    required this.email,
    required this.roles,
    this.fullName,
    this.universityId,
    this.facultyId,
    this.yearOfStudy,
    this.academicDataConsentedAt,
    this.primaryCourseUnitIds = const [],
  });

  /// Builds a profile from an auth or profile response body.
  ///
  /// Tolerant on the optional fields because they are genuinely absent for a new
  /// account: sign-up collects an address and a password, so a user with no name
  /// and no university is the normal first state rather than a malformed one.
  ///
  /// Throws [FormatException] when a *required* field is missing or the wrong
  /// type. That is a server fault rather than a state to render around, and
  /// saying so in this type is what lets the repository classify it: a bare cast
  /// failure here would surface as a `TypeError` and be filed as an unknown
  /// error, which is a different thing and tells a student nothing.
  factory UserProfile.fromJson(Map<String, dynamic> json) {
    // A role the client does not recognise is dropped rather than thrown on.
    // The pilot is still adding roles, and a new one should show up as a student
    // with fewer capabilities rather than as a crash on launch.
    final roles = (json['roles'] as List<dynamic>? ?? const <dynamic>[])
        // `as String?` rather than `as String` so a role that arrives as a
        // number or a map is an unknown role, not a TypeError. The tolerance
        // above is only worth claiming if it holds for every shape, not just
        // the string one.
        .map((role) => UserRole.fromWire(role is String ? role : null))
        .whereType<UserRole>()
        .toSet();

    final id = json['id'];
    final email = json['email'];
    if (id is! String || email is! String) {
      throw const FormatException(
        'user response carried no public id or email',
      );
    }

    return UserProfile(
      publicId: id,
      email: email,
      fullName: json['full_name'] as String?,
      roles: roles,
      universityId: json['university_id'] as String?,
      facultyId: json['faculty_id'] as String?,
      yearOfStudy: (json['year_of_study'] as num?)?.toInt(),
      academicDataConsentedAt: json['academic_data_consented_at'] == null
          ? null
          : DateTime.parse(json['academic_data_consented_at'] as String),
      primaryCourseUnitIds:
          (json['primary_course_unit_ids'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(),
    );
  }

  final String publicId;

  final String email;

  /// The name, as one string.
  ///
  /// The API stores one column and the wizard collects one field. There is no
  /// first name and surname on the wire, so [firstName] and [initials] are
  /// derived here rather than being transmitted and stored separately.
  final String? fullName;

  final Set<UserRole> roles;

  final String? universityId;

  final String? facultyId;

  final int? yearOfStudy;

  /// When consent to process academic records was given.
  ///
  /// Null for an account that has not consented. The API only ever sets this
  /// once: a client re-sending consent must not restate the date, because it
  /// records when the student agreed, not how many times the app asked.
  final DateTime? academicDataConsentedAt;

  /// The course units the student flagged as ones they will need help with.
  ///
  /// Seeded in the third step of the onboarding wizard. Empty for accounts that
  /// have not completed that step yet.
  final List<String> primaryCourseUnitIds;

  bool hasRole(UserRole role) => roles.contains(role);

  bool get hasConsentedToAcademicData => academicDataConsentedAt != null;

  /// Whether the wizard still has to run.
  ///
  /// Three conditions: name, university (matching requires a grading scale) and
  /// faculty (the course catalogue and the tutor rail are scoped to it, so
  /// without one there is nothing to show).
  ///
  /// Faculty is listed here because it became a requirement of the API rather
  /// than a preference: the catalogue answers for one faculty, so an account
  /// without one is served an empty one and every course screen behind this gate
  /// looks broken. Choosing a faculty is step two of the wizard, so sending the
  /// account back through it is a step it already knows how to take.
  ///
  /// Primary course units are deliberately NOT a condition here, though the
  /// wizard asks for one. Four of the six seeded faculties publish no course
  /// units at all, so a gate that requires a declared unit would send a student
  /// of one of them back through the wizard on every launch, for ever, with no
  /// way to satisfy it -- the gate would outlive the thing it was waiting for.
  /// The module step still asks, and still has to be finished or acknowledged to
  /// leave the wizard; what it does not do is bar the app to a student who has
  /// answered it as fully as their faculty allows. Declared units are a matching
  /// input, and no endpoint reads them as a precondition of anything else.
  bool get needsOnboarding =>
      (fullName == null || fullName!.trim().isEmpty) ||
      universityId == null ||
      facultyId == null;

  /// The part of the name a greeting uses, or null when there is no name.
  ///
  /// Falls back to the whole name when it has one word, rather than guessing a
  /// split that may cut a compound name in the wrong place.
  String? get firstName {
    final name = fullName?.trim();
    if (name == null || name.isEmpty) return null;
    final firstSpace = name.indexOf(' ');
    if (firstSpace == -1) return name;
    return name.substring(0, firstSpace);
  }

  /// Up to two initials for the placeholder avatar.
  ///
  /// Derived rather than uploaded: the pilot stores no images, and a client-side
  /// upload would put someone's face in a bucket the API does not describe.
  String get initials {
    final words = fullName?.trim().split(RegExp(r'\s+')) ?? const <String>[];
    final letters = [
      for (final word in words)
        if (word.isNotEmpty) word[0].toUpperCase(),
    ];
    if (letters.isEmpty) return '?';
    return letters.take(2).join();
  }

  UserProfile copyWith({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    DateTime? academicDataConsentedAt,
    List<String>? primaryCourseUnitIds,
  }) {
    return UserProfile(
      publicId: publicId,
      email: email,
      roles: roles,
      fullName: fullName ?? this.fullName,
      universityId: universityId ?? this.universityId,
      facultyId: facultyId ?? this.facultyId,
      yearOfStudy: yearOfStudy ?? this.yearOfStudy,
      academicDataConsentedAt:
          academicDataConsentedAt ?? this.academicDataConsentedAt,
      primaryCourseUnitIds: primaryCourseUnitIds ?? this.primaryCourseUnitIds,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          other.publicId == publicId &&
          other.email == email &&
          other.fullName == fullName &&
          other.universityId == universityId &&
          other.facultyId == facultyId &&
          other.yearOfStudy == yearOfStudy &&
          other.academicDataConsentedAt == academicDataConsentedAt &&
          setEquals(other.roles, roles) &&
          listEquals(other.primaryCourseUnitIds, primaryCourseUnitIds);

  @override
  int get hashCode => Object.hash(
    publicId,
    email,
    fullName,
    universityId,
    facultyId,
    yearOfStudy,
    academicDataConsentedAt,
    Object.hashAllUnordered(roles),
    Object.hashAll(primaryCourseUnitIds),
  );

  @override
  String toString() =>
      'UserProfile($publicId, $email, name: $fullName, roles: $roles)';
}
