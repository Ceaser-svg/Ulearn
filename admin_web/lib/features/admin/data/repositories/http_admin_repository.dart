import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/models/admin_tutor_standing.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/core/network/admin_api_client.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';

/// The repository the console runs on.
///
/// All of the console's reads are paged lists and its one write is a review, so
/// this class is small on purpose: JSON in, typed rows out, with the paging
/// arithmetic left to [AdminPageRequest].
class HttpAdminRepository implements AdminRepository {
  const HttpAdminRepository(this._client);

  final AdminApiClient _client;

  @override
  Future<AdminSession> signIn(String email, String password) async {
    final body = await _client.signIn(email, password);
    final tokens = body['tokens'] as Map<String, dynamic>?;
    final user = body['user'] as Map<String, dynamic>?;
    final roles = (user?['roles'] as List<dynamic>? ?? const <dynamic>[])
        .map((role) => role.toString())
        .toSet();
    if (tokens == null || user == null) {
      throw const FormatException('The server returned an incomplete sign-in.');
    }
    if (!roles.contains('admin')) {
      throw const AdminAccessException();
    }
    final session = AdminSession(
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String,
      email: user['email'] as String,
    );
    _client.adoptSession(session);
    return session;
  }

  @override
  Future<AdminPage<AdminUser>> users(AdminPageRequest request) =>
      _page('/v1/admin/users', request, AdminUser.fromJson);

  @override
  Future<AdminPage<AuditEvent>> auditEvents(AdminPageRequest request) =>
      _page('/v1/admin/audit-events', request, AuditEvent.fromJson);

  @override
  Future<AdminPage<AdminCompetency>> competencies(AdminPageRequest request) =>
      _page('/v1/admin/competencies', request, AdminCompetency.fromJson);

  @override
  Future<AdminPage<AdminTutorStanding>> tutorStandings(
    AdminPageRequest request,
  ) => _page('/v1/admin/tutor-standings', request, AdminTutorStanding.fromJson);

  @override
  Future<void> reviewCompetency(
    AdminCompetency competency,
    String status, {
    String? reason,
  }) => _client.patch(
    '/v1/admin/competencies/${competency.id}/review',
    data: <String, dynamic>{
      'status': status,
      ...?reason == null ? null : <String, dynamic>{'rejection_reason': reason},
    },
  );

  @override
  void signOut() => _client.signOut();

  Future<AdminPage<T>> _page<T>(
    String path,
    AdminPageRequest request,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final body = await _client.getPage(
      path,
      offset: request.offset,
      limit: request.limit,
    );
    return AdminPage<T>.fromJson(body, parse);
  }
}
