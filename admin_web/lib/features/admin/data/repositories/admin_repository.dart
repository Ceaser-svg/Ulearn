import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/models/admin_tutor_standing.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';

/// Thrown when an account authenticates but is not provisioned for the console.
///
/// A distinct type because it is not a transport failure: retrying it will
/// never help, and it means something different to an operator than a server
/// error does.
class AdminAccessException implements Exception {
  const AdminAccessException();
}

/// The console's read and write surface, as the screens need it.
///
/// Every list is paged, because the API serves pages and an operator has to be
/// able to reach a row the first page did not hold.
///
/// Abstract so that a screen can be exercised against an in-memory console
/// without an API and a database behind it. There is no other way to test
/// these lists.
abstract class AdminRepository {
  Future<AdminSession> signIn(String email, String password);

  Future<AdminPage<AdminUser>> users(AdminPageRequest request);

  Future<AdminPage<AuditEvent>> auditEvents(AdminPageRequest request);

  /// The review queue, narrowed to [status] when one is given.
  ///
  /// The filter is sent to the API rather than applied here because the API
  /// owns the `total`: a client-side filter would report a count of the rows it
  /// happened to be holding, and the pager would offer a second page that does
  /// not exist.
  Future<AdminPage<AdminCompetency>> competencies(
    AdminPageRequest request, {
    CompetencyStatus? status,
  });

  Future<AdminPage<AdminTutorStanding>> tutorStandings(
    AdminPageRequest request,
  );

  /// Records an operator's decision on a competency.
  ///
  /// [reason] is required by the API when [status] is `rejected`; the console
  /// asks for it before calling rather than relying on the 422, because a
  /// field-level message on a modal dialog the operator has already filled in
  /// is a worse experience than the dialog asking in the first place.
  Future<void> reviewCompetency(
    AdminCompetency competency,
    String status, {
    String? reason,
  });

  /// Ends the session from the console's side, credentials included.
  Future<void> signOut();
}
