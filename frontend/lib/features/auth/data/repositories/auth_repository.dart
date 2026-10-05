import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit_option.dart';
import 'package:peerpass/core/models/grade_option.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/university_option.dart';
import 'package:peerpass/core/models/user_profile.dart';
/// The authentication and own-profile contract the rest of the client depends
/// on.
///
/// Every method throws a [Failure], never a transport exception. Translating
/// `DioException` and RFC 9457 problem documents into [Failure] happens in the
/// implementation, so a screen renders a message and never has to know whether
/// the API answered with a socket error or a problem document.
abstract interface class AuthRepository {
  /// Signs in with an address and a password, and stores the returned tokens.
  Future<UserProfile> signIn({required String email, required String password});

  /// Creates the account and signs it in.
  ///
  /// The API returns a session with the registration, so the client does not
  /// have to follow this with a sign-in the user did not ask for.
  Future<UserProfile> register({
    required String email,
    required String password,
  });

  /// The signed-in user's own record, or null when there is no session.
  ///
  /// Called on cold start. Implementations must spend the refresh token to get
  /// an access token and then clear the session rather than surfacing an error,
  /// because a token the server no longer honours *is* the definition of signed
  /// out. A network failure is the one case worth reporting: it is retryable and
  /// a student on a bad connection should be told so rather than signed out.
  Future<UserProfile?> restoreSession();

  /// Renews the access token, returning whether the session survived.
  ///
  /// The shape the auth interceptor wants: a bool, because the interceptor's only
  /// question is whether to retry the request that got a `401`.
  Future<bool> refreshSession();

  /// The universities the picker offers.
  Future<List<UniversityOption>> universities();

  /// Resolves a public university identifier to its display name.
  Future<String?> universityNameById(String universityId);

  /// The faculties the picker offers.
  Future<List<Subject>> faculties({required String universityId});

  /// Course units for the given university, for the primary modules step.
  Future<List<CourseUnitOption>> courseUnits({
    String? universityId,
    String? subjectId,
  });

  /// Every grade on the university's published scale.
  Future<List<GradeOption>> grades({String? universityId});

  /// Submits transcript or portfolio evidence for a unit the user claims to know.
  Future<void> submitCompetency({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  });

  /// Updates the caller's own profile, returning the stored record.
  ///
  /// Partial by design. The wizard saves one step at a time, so a step that sent
  /// the whole record would blank the university chosen on the previous screen.
  Future<UserProfile> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  });

  /// Discards the stored session on this device.
  Future<void> signOut();

  /// Asks the API to anonymise the signed-in account, then ends the session.
  ///
  /// Not the same thing as [signOut], and the ordering is deliberate. Sign-out
  /// discards the tokens and leaves the account intact; this anonymises the
  /// account, after which the tokens are worthless and every later request comes
  /// back `401`. The caller is expected to end up signed out either way, because
  /// a deleted account that still held a live session would be an account the
  /// person asked to stop existing and could keep using.
  ///
  /// The tokens are cleared locally *before* the call is trusted, for the same
  /// reason [signOut] does it: a network failure must still leave the device in
  /// the state the user asked for, and the server-side anonymisation is
  /// idempotent so a retry cannot double-scrub.
  ///
  /// Throws a [Failure] if the request does not reach a deleted account. The
  /// session is cleared regardless, because leaving a student in the app with a
  /// token the server has already refused would strand them on a screen that
  /// cannot load.
  Future<void> deleteAccount();
}

/// The auth contract, as a live instance.
///
/// Declared in the contract file rather than beside the auth screens, because it
/// is the handle by which *other* features reach this feature. AGENTS.md allows
/// exactly one cross-feature dependency: the owning feature's repository contract.
/// A provider living in `presentation/` could not be imported by a sibling
/// feature without also importing its screens, so the handle has to sit here.
///
/// Throwing rather than defaulting keeps a missing override loud: a silent fake
/// default would let a build ship pointed at nothing.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => throw UnimplementedError(
    'authRepositoryProvider must be overridden in ProviderScope.',
  ),
);
