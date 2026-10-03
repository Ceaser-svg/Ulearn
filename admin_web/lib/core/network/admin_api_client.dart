import 'package:dio/dio.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';

/// Reports that the console can no longer make an authenticated request.
///
/// Called from [AdminApiClient.signOut] so that whoever owns the session can
/// drop it. The client cannot do that itself: it holds tokens, not a session,
/// and it has no business deciding what an operator is shown once the
/// credentials behind it are gone.
typedef SessionExpiredCallback = void Function();

/// The console's transport.
///
/// Owns the bearer token, the refresh token, and the single retry a 401 is
/// allowed. It deliberately knows nothing about what the endpoints return: it
/// hands back decoded JSON and lets the repository decide what it means, so a
/// transport fault and a schema fault cannot be confused for one another in a
/// stack trace.
class AdminApiClient {
  AdminApiClient({required this.baseUrl, Dio? dio, this.onSessionExpired})
    : _dio = dio ?? buildDio(baseUrl);

  /// The console's HTTP defaults: bounded waits, and any non-2xx thrown instead
  /// of returned so a rejected request arrives as an error rather than as a
  /// body to be parsed.
  static Dio buildDio(String baseUrl) => Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (status) =>
          status != null && status >= 200 && status < 300,
    ),
  );

  final String baseUrl;
  final Dio _dio;

  /// Invoked whenever the credentials stop working, whether the operator asked
  /// to sign out or a refresh failed under them.
  final SessionExpiredCallback? onSessionExpired;

  String? _accessToken;
  String? _refreshToken;

  /// The refresh currently in flight, so a burst of 401s spends one refresh
  /// rather than one per request. Two of them would race, and the loser would
  /// install a token the winner has already rotated away.
  Future<bool>? _refreshInFlight;

  /// Authenticates and returns the raw sign-in body for the repository to
  /// read. Nothing is held here: the repository has to confirm the account is
  /// provisioned for this console first, and it says so by calling
  /// [adoptSession].
  Future<Map<String, dynamic>> signIn(String email, String password) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/login',
      data: <String, dynamic>{'email': email, 'password': password},
    );
    return response.data!;
  }

  /// Takes the credentials a validated sign-in produced.
  ///
  /// Deliberately not part of [signIn]. An account without the admin role
  /// authenticates successfully and is then refused, and a transport that
  /// stored its tokens on the way in would be holding a credential for a
  /// refused account until something remembered to drop it.
  void adoptSession(AdminSession session) {
    _accessToken = session.accessToken;
    _refreshToken = session.refreshToken;
  }

  /// Reads one offset/limit page and returns the raw envelope.
  Future<Map<String, dynamic>> getPage(
    String path, {
    required int offset,
    required int limit,
  }) async {
    final response = await _authorized(
      () => _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: <String, dynamic>{'offset': offset, 'limit': limit},
        options: _authOptions(),
      ),
    );
    return response.data!;
  }

  /// Sends a write and discards the response body.
  Future<void> patch(String path, {required Map<String, dynamic> data}) async {
    await _authorized(
      () => _dio.patch<Map<String, dynamic>>(
        path,
        data: data,
        options: _authOptions(),
      ),
    );
  }

  /// Drops the credentials and reports that the session is over.
  ///
  /// Reporting is what makes a refresh failure visible: without it the console
  /// keeps rendering as signed in while every request it makes is rejected.
  /// Clearing the tokens is not enough, because the data already fetched is
  /// still in memory and still confidential.
  void signOut() {
    _accessToken = null;
    _refreshToken = null;
    onSessionExpired?.call();
  }

  Options _authOptions() => Options(
    headers: <String, dynamic>{'Authorization': 'Bearer $_accessToken'},
  );

  /// Runs [request], and on a 401 refreshes once and runs it again.
  ///
  /// One retry, never a loop: if the second attempt is also rejected the
  /// response propagates, and the refresh attempt in between has already
  /// cleared the session if it failed.
  Future<Response<T>> _authorized<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      if (error.response?.statusCode != 401 || !await _refresh()) {
        rethrow;
      }
      return await request();
    }
  }

  Future<bool> _refresh() async {
    final token = _refreshToken;
    if (token == null) {
      // No refresh token is a failed authentication as much as a rejected
      // refresh is, and the console has to hear about it: leaving the operator
      // looking signed in with no way to make a request succeed is the state
      // this reporting exists to end.
      signOut();
      return false;
    }
    final inFlight = _refreshInFlight;
    if (inFlight != null) return await inFlight;

    final future = _refreshInFlight = () async {
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          '/v1/auth/refresh',
          data: <String, dynamic>{'refresh_token': token},
        );
        final tokens = response.data?['tokens'] as Map<String, dynamic>?;
        final access = tokens?['access_token'];
        final refresh = tokens?['refresh_token'];
        if (access is! String || refresh is! String) {
          signOut();
          return false;
        }
        _accessToken = access;
        _refreshToken = refresh;
        return true;
      } on DioException {
        signOut();
        return false;
      } finally {
        _refreshInFlight = null;
      }
    }();
    return await future;
  }
}
