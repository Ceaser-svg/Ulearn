import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// A token pair and the user record it belongs to, exactly as the API sends
/// them.
///
/// The two are one response because the API sends them as one. Splitting them
/// here would mean two fields that must be kept in step for no gain.
@immutable
class AuthPayload {
  const AuthPayload({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  /// Reads the wire form.
  ///
  /// Throws [FormatException] on a response with no tokens, because there is
  /// nothing to authenticate with and returning a half-built payload would fail
  /// later, further from the cause.
  factory AuthPayload.fromJson(Map<String, dynamic> json) {
    final tokens = json['tokens'] as Map<String, dynamic>?;
    if (tokens == null) {
      throw const FormatException('auth response carried no tokens');
    }
    return AuthPayload(
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String,
      user: json['user'] as Map<String, dynamic>,
    );
  }

  final String accessToken;

  final String refreshToken;

  /// The user record, still as raw JSON.
  ///
  /// Kept as JSON rather than a typed model so this layer does not decide what
  /// the client thinks a user is. The repository is where the wire shape becomes
  /// a profile, so there is one place to look when the two disagree.
  final Map<String, dynamic> user;
}

/// Talks to the five `/v1/auth` endpoints and to the caller's own profile.
///
/// Throws [DioException], not a `Failure`. Classification belongs to
/// `core/network/network_exceptions.dart` and happens once, in the repository,
/// so that a transport error and a problem document are translated by the same
/// code whichever endpoint produced them.
class RemoteAuthDatasource {
  const RemoteAuthDatasource(this._dio);

  final Dio _dio;

  /// Creates the account and signs it straight in.
  ///
  /// The API returns a token pair with the registration rather than making the
  /// client sign in immediately after, so a new student lands on onboarding with
  /// a session already established.
  Future<AuthPayload> register({
    required String email,
    required String password,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/register',
      data: {'email': email, 'password': password},
    );
    return AuthPayload.fromJson(response.data!);
  }

  Future<AuthPayload> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/login',
      data: {'email': email, 'password': password},
    );
    return AuthPayload.fromJson(response.data!);
  }

  /// Exchanges a refresh token for a new pair.
  ///
  /// Goes through the same client as everything else, so it carries the same
  /// base URL and timeouts. It is a bare `Dio` call on purpose: the auth
  /// interceptor would attach the access token to it, and on a `401` it would
  /// try to refresh again -- which is the request that just failed.
  Future<AuthPayload> refresh(String refreshToken) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/refresh',
      data: {'refresh_token': refreshToken},
    );
    return AuthPayload.fromJson(response.data!);
  }

  /// Ends the session server-side.
  ///
  /// The token is optional because a client that has already cleared its store
  /// must still be able to sign out, and because signing out is not a request
  /// worth failing the user's tap over.
  Future<void> signOut(String? refreshToken) async {
    await _dio.post<void>(
      '/v1/auth/logout',
      data: refreshToken == null ? null : {'refresh_token': refreshToken},
    );
  }

  /// Anonymises the caller's own account.
  ///
  /// `204` with no body, so there is nothing to parse and no representation of
  /// the account to keep in step on the client. The success case is the status
  /// code itself.
  Future<void> deleteAccount() async {
    await _dio.delete<void>('/v1/users/me');
  }

  /// The caller's own record, for a cold start that has a session but no profile.
  Future<Map<String, dynamic>> me() async {
    final response = await _dio.get<Map<String, dynamic>>('/v1/auth/me');
    return response.data!;
  }

  /// Updates the caller's own profile.
  ///
  /// Every field is optional and only the ones supplied are sent. The wizard
  /// saves one step at a time, so a step that sent the whole record would blank
  /// the university chosen on the previous screen.
  Future<Map<String, dynamic>> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  }) async {
    final data = <String, dynamic>{};
    if (fullName != null) data['full_name'] = fullName;
    if (universityId != null) data['university_id'] = universityId;
    if (facultyId != null) data['faculty_id'] = facultyId;
    if (yearOfStudy != null) data['year_of_study'] = yearOfStudy;
    if (academicDataConsented != null) {
      data['academic_data_consented'] = academicDataConsented;
    }
    if (primaryCourseUnitIds != null) {
      data['primary_course_unit_ids'] = primaryCourseUnitIds;
    }

    final response = await _dio.patch<Map<String, dynamic>>(
      '/v1/users/me',
      data: data,
    );
    return response.data!;
  }
}
