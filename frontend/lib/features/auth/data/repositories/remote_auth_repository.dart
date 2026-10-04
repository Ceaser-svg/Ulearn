import 'package:dio/dio.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/network/network_exceptions.dart';
import 'package:peerpass/core/storage/token_store.dart';
import 'package:peerpass/features/auth/data/datasources/remote_academics_datasource.dart';
import 'package:peerpass/features/auth/data/datasources/remote_auth_datasource.dart';
import 'package:peerpass/features/auth/data/models/university_option.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';

/// [AuthRepository] over the real API.
///
/// The only place that knows the wire format and the token store at the same
/// time: tokens are written here, on the way out, and never by a screen. That is
/// what makes "the access token is in memory only" hold, because there is no
/// other code path that could put one anywhere else.
class RemoteAuthRepository implements AuthRepository {
  const RemoteAuthRepository({
    required this.auth,
    required this.academics,
    required this.tokenStore,
  });

  /// The auth endpoints.
  ///
  /// Public and final rather than private behind a named parameter. A private
  /// field cannot be an initializing formal, because a named parameter cannot
  /// be private, so the pair cannot be written without a suppression. The
  /// fields are read-only and injected by the composition root, so exposing
  /// them grants no capability that constructing the repository did not.
  final RemoteAuthDatasource auth;

  /// The academic lookups.
  final RemoteAcademicsDatasource academics;

  /// Where tokens are read and written.
  final TokenStore tokenStore;

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) {
    return _establish(() => auth.signIn(email: email, password: password));
  }

  @override
  Future<UserProfile> register({
    required String email,
    required String password,
  }) {
    return _establish(() => auth.register(email: email, password: password));
  }

  @override
  Future<UserProfile?> restoreSession() async {
    final refreshToken = await tokenStore.readRefreshToken();
    if (refreshToken == null) return null;

    try {
      // Spend the refresh token for a fresh pair, then ask who it belongs to.
      // The pair alone is not enough: the router needs to know whether this
      // account still has to run the wizard, and that is in the user record.
      final renewed = await auth.refresh(refreshToken);
      await tokenStore.write(
        accessToken: renewed.accessToken,
        refreshToken: renewed.refreshToken,
      );
      return UserProfile.fromJson(await auth.me());
    } on Object catch (error) {
      final failure = _toFailure(error);
      if (failure is AuthFailure) {
        // The server no longer honours this token. Clear it, so the next cold
        // start does not replay the same dead credential, and report signed out
        // rather than as an error the user has to act on.
        await tokenStore.clear();
        return null;
      }
      throw failure;
    }
  }

  @override
  Future<bool> refreshSession() async {
    final refreshToken = await tokenStore.readRefreshToken();
    if (refreshToken == null) return false;

    try {
      final renewed = await auth.refresh(refreshToken);
      await tokenStore.write(
        accessToken: renewed.accessToken,
        refreshToken: renewed.refreshToken,
      );
      return true;
    } on Object {
      // A refresh that fails leaves the interceptor to surface the original
      // `401`, which is the more useful message. Clearing here is what stops the
      // next request trying a token the server has already refused.
      await tokenStore.clear();
      return false;
    }
  }

  @override
  Future<List<UniversityOption>> universities() =>
      _guard(academics.universities);

  @override
  Future<String?> universityNameById(String universityId) async {
    final universities = await this.universities();
    for (final university in universities) {
      if (university.publicId == universityId) return university.name;
    }
    return null;
  }

  @override
  Future<List<Subject>> faculties({required String universityId}) =>
      _guard(() => academics.faculties(universityId: universityId));

  @override
  Future<List<CourseUnitOption>> courseUnits({
    String? universityId,
    String? subjectId,
  }) => _guard(
    () =>
        academics.courseUnits(universityId: universityId, subjectId: subjectId),
  );

  @override
  Future<List<GradeOption>> grades({String? universityId}) =>
      _guard(() => academics.grades(universityId: universityId));

  @override
  Future<void> submitCompetency({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  }) => _guard(
    () => auth.submitCompetency(
      courseUnitId: courseUnitId,
      gradeId: gradeId,
      source: source,
      evidenceReference: evidenceReference,
      notes: notes,
    ),
  );

  @override
  Future<UserProfile> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  }) {
    // The same reason as `_establish`: the parse belongs inside the guard.
    return _guard(
      () => auth
          .updateProfile(
            fullName: fullName,
            universityId: universityId,
            facultyId: facultyId,
            yearOfStudy: yearOfStudy,
            academicDataConsented: academicDataConsented,
            primaryCourseUnitIds: primaryCourseUnitIds,
          )
          .then(UserProfile.fromJson),
    );
  }

  @override
  Future<void> signOut() async {
    final refreshToken = await tokenStore.readRefreshToken();
    // Clear locally first, and unconditionally. A sign-out that failed because
    // the network is down must still leave the device signed out; the server
    // will expire the token on its own, and the user's intent is not conditional
    // on the network.
    await tokenStore.clear();
    try {
      await auth.signOut(refreshToken);
    } on Object {
      // Nothing to do. The local session is gone, which is what the user asked
      // for, and the token is dead on the server once it expires.
    }
  }

  @override
  Future<void> deleteAccount() async {
    // The opposite order to [signOut], and deliberately so. Deletion is
    // authorised by the access token, so clearing the store first would send the
    // request with no credential at all: the server would answer 401, and the
    // one outcome that leaves the user worse off than not tapping the button.
    // [signOut] can clear first because it reads the refresh token before it
    // does, and because failing to tell the server is harmless when the token
    // expires on its own.
    //
    // Clearing afterwards is also what makes a failed delete recoverable. The
    // tokens survive it, so the session is still good and "your account is
    // unchanged, try again" is a thing the user can act on rather than a
    // sentence explaining why they have just been signed out.
    //
    // Guarded like every other call here, unlike [signOut]. Sign-out genuinely
    // cannot fail as far as its caller is concerned, but this one reports what
    // went wrong in a sentence the screen can print; an untranslated
    // [DioException] would sail past the screen's `on Failure` and leave the
    // user with no explanation at all.
    await _guard(auth.deleteAccount);
    await tokenStore.clear();
  }

  /// Signs in or registers, and persists the tokens before returning the user.
  ///
  /// The reading of the body is inside the guard, not applied to its result. A
  /// malformed response is a server fault, and a parse that happened after the
  /// guard had returned would escape every translation here and reach the screen
  /// as a bare `FormatException`.
  Future<UserProfile> _establish(Future<AuthPayload> Function() call) {
    return _guard(() async {
      final payload = await call();
      final profile = UserProfile.fromJson(payload.user);
      // Parsed before it is written, so a body that cannot be read cannot leave
      // a stored session that the app has no profile to render.
      await tokenStore.write(
        accessToken: payload.accessToken,
        refreshToken: payload.refreshToken,
      );
      return profile;
    });
  }

  /// Runs a call and translates whatever comes back into a [Failure].
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on Object catch (error) {
      throw _toFailure(error);
    }
  }

  Failure _toFailure(Object error) {
    if (error is Failure) return error;
    if (error is FormatException) {
      // The API answered with something that is not the shape it documents.
      // Reported as a server fault rather than an unknown one, because that is
      // what it is, and a student cannot act on it either way.
      return const ServerFailure(
        'The server sent something we could not read.',
      );
    }
    if (error is DioException) return mapDioException(error);
    return const UnknownFailure();
  }
}
