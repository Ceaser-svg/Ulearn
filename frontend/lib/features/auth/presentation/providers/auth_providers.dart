import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/academic_fallback.dart';
import 'package:peerpass/core/models/course_unit_option.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/university_option.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
/// The auth operations, as calls the screens can make.
///
/// Performs authentication against the repository and records the outcome in
/// [SessionController]. It owns no session state of its own, so "who is signed
/// in" has exactly one home regardless of whether it was established by a
/// sign-in, a sign-up, a profile update, or a cold-start restore.
///
/// A plain [Provider] rather than a [Notifier]: it exposes no value of its own,
/// and a notifier that never does is one pretending to be something it is not.
/// Its single piece of behaviour is starting the cold-start check the first time
/// anything reads it, which is why the body is not a bare constructor.
final authControllerProvider = Provider<AuthController>((ref) {
  final controller = AuthController(ref)..startRestore();
  return controller;
});

class AuthController {
  const AuthController(this._ref);

  final Ref _ref;

  AuthRepository get _repository => _ref.read(authRepositoryProvider);

  SessionController get _session =>
      _ref.read(sessionControllerProvider.notifier);

  /// Signs in and adopts the account the API returns.
  Future<void> signIn({required String email, required String password}) async {
    final profile = await _repository.signIn(email: email, password: password);
    _session.signedIn(profile);
  }

  /// Creates the account, which the API signs straight in.
  ///
  /// The new account has no name yet, so the router sends it to onboarding. The
  /// controller does not care; deciding where a profile leads is the router's job
  /// and duplicating that rule here would give two places to get it wrong.
  Future<void> register({
    required String email,
    required String password,
  }) async {
    final profile = await _repository.register(
      email: email,
      password: password,
    );
    _session.signedIn(profile);
  }

  /// Updates the profile and adopts the stored record the API returns.
  Future<void> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  }) async {
    final profile = await _repository.updateProfile(
      fullName: fullName,
      universityId: universityId,
      facultyId: facultyId,
      yearOfStudy: yearOfStudy,
      academicDataConsented: academicDataConsented,
      primaryCourseUnitIds: primaryCourseUnitIds,
    );
    _session.signedIn(profile);
  }

  /// Ends the session and returns to the signed-out state.
  Future<void> signOut() async {
    await _repository.signOut();
    _session.signedOut();
  }

  /// Tries the cold-start check again after it failed.
  ///
  /// Offered by the splash screen. Without it a student whose connection dropped
  /// on launch has no way forward but force-quitting the app, which on a
  /// low-memory handset is not something they will think to do.
  Future<void> retryRestore() => _restore();

  /// Starts the cold-start check of the stored session.
  ///
  /// Called once, by [authControllerProvider] when it is first read, rather than
  /// exposed for the shell to remember to invoke -- a check nobody calls is a
  /// check that never happens, and an app held on splash forever.
  void startRestore() => unawaited(_restore());

  Future<void> _restore() async {
    try {
      final profile = await _repository.restoreSession();
      if (profile == null) {
        _session.signedOut();
      } else {
        _session.signedIn(profile);
      }
    } on NetworkFailure catch (failure) {
      _session.stillUnknown(restoreFailure: failure);
    } on Failure {
      // Anything else means the stored session is not usable, which is the
      // definition of signed out.
      _session.signedOut();
    }
  }
}

/// The universities the wizard offers.
final universitiesProvider = FutureProvider<List<UniversityOption>>((
  ref,
) async {
  try {
    final universities = await ref.read(authRepositoryProvider).universities();
    return universities.isEmpty ? const [mustFallbackUniversity] : universities;
  } on Object {
    return const [mustFallbackUniversity];
  }
});

/// The faculties the wizard offers.
// ignore: specify_nonobvious_property_types
final facultiesProvider = FutureProvider.family<List<Subject>, String>((
  ref,
  universityId,
) async {
  if (isMustFallbackUniversity(universityId)) {
    return mustFallbackFaculties;
  }
  try {
    final faculties = await ref
        .read(authRepositoryProvider)
        .faculties(universityId: universityId);
    return faculties;
  } on Failure {
    rethrow;
  }
});

typedef CourseUnitScope = ({String universityId, String? subjectId});

/// Course units scoped to the selected university and, when known, faculty.
// Riverpod infers the family provider type from the generic parameters, and the
// analyzer does not surface that type in a way it can prove without the
// explicit ignore.
// ignore: specify_nonobvious_property_types
final courseUnitsProvider =
    FutureProvider.family<List<CourseUnitOption>, CourseUnitScope>((
      ref,
      scope,
    ) {
      if (scope.universityId.isEmpty) return Future.value(const []);
      return ref
          .read(authRepositoryProvider)
          .courseUnits(
            universityId: scope.universityId,
            subjectId: scope.subjectId,
          );
    });
