import 'dart:async';

import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/storage/token_store.dart';
import 'package:peerpass/features/auth/data/datasources/remote_academics_datasource.dart';
import 'package:peerpass/features/auth/data/models/university_option.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';

/// In-memory stand-in for the auth endpoints.
///
/// What the running app resolved while the API had no auth endpoints, and what
/// widget tests still resolve now, because a widget test has no server to talk
/// to. A session can be injected to simulate a returning user, which is how the
/// shell test covers the authenticated branch, and the pending restore holds the
/// cold-start gate open while a test decides what the stored token turns into.
///
/// It implements the repository's shape rather than the datasource's, because
/// that is the seam a test cares about: overriding the repository is the only
/// composition the app supports.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({
    this.session,
    this.refreshToken,
    this.universityOptions = const [],
    this.facultyOptions = const [],
    this.courseUnitOptions = const [],
    this.gradeOptions = const [],
    this._pendingRestore,
    TokenStore? tokenStore,
  }) : _tokenStore = tokenStore ?? InMemoryTokenStore();

  /// The account this repository reports as signed in, or null for signed out.
  UserProfile? session;

  /// The stored refresh token, or null to simulate a device that has never been
  /// signed in.
  String? refreshToken;

  /// The universities [universities] hands back.
  List<UniversityOption> universityOptions;

  /// The faculties [faculties] hands back.
  List<Subject> facultyOptions;

  /// The course units [courseUnits] hands back.
  List<CourseUnitOption> courseUnitOptions;

  /// The grades [grades] hands back.
  List<GradeOption> gradeOptions;

  final Completer<UserProfile?>? _pendingRestore;
  final TokenStore _tokenStore;

  final List<Map<String, Object?>> submittedCompetencies = [];

  /// Every [updateProfile] call, in order.
  ///
  /// A test asserts on this to check what the wizard actually sent, which is the
  /// only way to catch a step that overwrites a field it should have left alone.
  final List<Map<String, Object?>> profileUpdates = [];

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) async {
    final current = session;
    if (current == null) {
      throw StateError('FakeAuthRepository.signIn called with no session set');
    }
    await _tokenStore.write(accessToken: 'access', refreshToken: 'refresh');
    return current;
  }

  @override
  Future<UserProfile> register({
    required String email,
    required String password,
  }) async {
    session = UserProfile(
      publicId: 'new-user',
      email: email,
      roles: const {UserRole.student},
    );
    await _tokenStore.write(accessToken: 'access', refreshToken: 'refresh');
    return session!;
  }

  @override
  Future<UserProfile?> restoreSession() {
    final pending = _pendingRestore;
    if (pending != null) return pending.future;
    return Future.value(refreshToken == null ? null : session);
  }

  @override
  Future<bool> refreshSession() async => refreshToken != null;

  @override
  Future<List<UniversityOption>> universities() async => universityOptions;

  @override
  Future<String?> universityNameById(String universityId) async {
    for (final university in universityOptions) {
      if (university.publicId == universityId) return university.name;
    }
    return null;
  }

  @override
  Future<List<Subject>> faculties({required String universityId}) async =>
      facultyOptions;

  @override
  Future<List<CourseUnitOption>> courseUnits({String? universityId}) async =>
      courseUnitOptions;

  @override
  Future<List<GradeOption>> grades({String? universityId}) async =>
      gradeOptions;

  @override
  Future<void> submitCompetency({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  }) async {
    submittedCompetencies.add({
      'course_unit_id': courseUnitId,
      'grade_id': gradeId,
      'source': source,
      'evidence_reference': evidenceReference,
      'notes': notes,
    });
  }

  @override
  Future<UserProfile> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  }) async {
    final payload = <String, Object?>{};
    if (fullName != null) payload['full_name'] = fullName;
    if (universityId != null) payload['university_id'] = universityId;
    if (facultyId != null) payload['faculty_id'] = facultyId;
    if (yearOfStudy != null) payload['year_of_study'] = yearOfStudy;
    if (academicDataConsented != null) {
      payload['academic_data_consented'] = academicDataConsented;
    }
    if (primaryCourseUnitIds != null) {
      payload['primary_course_unit_ids'] = primaryCourseUnitIds;
    }
    profileUpdates.add(payload);

    session = session?.copyWith(
      fullName: fullName,
      universityId: universityId,
      facultyId: facultyId,
      yearOfStudy: yearOfStudy,
      academicDataConsentedAt: academicDataConsented == true
          ? DateTime.utc(2026, 1, 15)
          : null,
      primaryCourseUnitIds: primaryCourseUnitIds,
    );
    return session!;
  }

  @override
  Future<void> signOut() async {
    session = null;
    refreshToken = null;
    await _tokenStore.clear();
  }

  @override
  Future<void> deleteAccount() async {
    // Mirrors the live ordering: the session goes first, unconditionally, so a
    // fake cannot end up modelling the state the real client refuses to be in.
    session = null;
    refreshToken = null;
    await _tokenStore.clear();
  }
}
