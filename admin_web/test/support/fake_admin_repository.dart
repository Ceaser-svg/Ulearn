import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/models/admin_tutor_standing.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';

/// One recorded review, so a test can assert what was asked for.
class RecordedReview {
  const RecordedReview(this.competency, this.status, this.reason);

  final AdminCompetency competency;
  final String status;
  final String? reason;
}

/// An in-memory console, so a screen can be exercised without an API and a
/// database behind it.
///
/// Slices exactly the way the API does -- `offset` and `limit` against a total
/// count -- so a paging test proves something about the request the console
/// sends, not just that a fake returned what it was told to.
class FakeAdminRepository implements AdminRepository {
  FakeAdminRepository({
    this.userRows = const <AdminUser>[],
    this.auditEventRows = const <AuditEvent>[],
    this.competencyRows = const <AdminCompetency>[],
    this.tutorStandingRows = const <AdminTutorStanding>[],
    this.session = const AdminSession(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      email: 'operator@peerpass.test',
    ),
    this.signInError,
    this.failNextReview = false,
    this.listError,
  });

  List<AdminUser> userRows;
  List<AuditEvent> auditEventRows;
  List<AdminCompetency> competencyRows;
  List<AdminTutorStanding> tutorStandingRows;
  AdminSession session;

  /// Thrown from [signIn] when set, for the failure paths.
  Error? signInError;

  /// Makes the next review throw a transport error.
  bool failNextReview;

  /// Thrown from every list read while set, for the failure paths.
  Error? listError;

  final List<AdminPageRequest> userRequests = <AdminPageRequest>[];
  final List<AdminPageRequest> auditEventRequests = <AdminPageRequest>[];
  final List<AdminPageRequest> competencyRequests = <AdminPageRequest>[];
  final List<AdminPageRequest> tutorStandingRequests = <AdminPageRequest>[];
  final List<RecordedReview> reviews = <RecordedReview>[];
  int signOutCount = 0;

  @override
  Future<AdminSession> signIn(String email, String password) async {
    final error = signInError;
    if (error != null) throw error;
    return session;
  }

  @override
  Future<AdminPage<AdminUser>> users(AdminPageRequest request) async {
    userRequests.add(request);
    _throwIfListError();
    return _slice(userRows, request);
  }

  @override
  Future<AdminPage<AuditEvent>> auditEvents(AdminPageRequest request) async {
    auditEventRequests.add(request);
    _throwIfListError();
    return _slice(auditEventRows, request);
  }

  @override
  Future<AdminPage<AdminCompetency>> competencies(
    AdminPageRequest request,
  ) async {
    competencyRequests.add(request);
    _throwIfListError();
    return _slice(competencyRows, request);
  }

  @override
  Future<AdminPage<AdminTutorStanding>> tutorStandings(
    AdminPageRequest request,
  ) async {
    tutorStandingRequests.add(request);
    _throwIfListError();
    return _slice(tutorStandingRows, request);
  }

  @override
  Future<void> reviewCompetency(
    AdminCompetency competency,
    String status, {
    String? reason,
  }) async {
    reviews.add(RecordedReview(competency, status, reason));
    if (failNextReview) {
      failNextReview = false;
      throw StateError('review rejected by the fake');
    }
  }

  @override
  void signOut() => signOutCount++;

  void _throwIfListError() {
    final error = listError;
    if (error != null) throw error;
  }

  AdminPage<T> _slice<T>(List<T> all, AdminPageRequest request) {
    final start = request.offset < all.length ? request.offset : all.length;
    final end = start + request.limit < all.length
        ? start + request.limit
        : all.length;
    return AdminPage<T>(
      items: all.sublist(start, end),
      total: all.length,
      limit: request.limit,
      offset: request.offset,
    );
  }
}
