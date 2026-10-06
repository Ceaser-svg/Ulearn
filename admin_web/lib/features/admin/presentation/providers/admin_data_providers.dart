import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_tutor_standing.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_list_controller.dart';

/// The pilot user list.
final adminUsersProvider =
    AsyncNotifierProvider<AdminUsersController, AdminPage<AdminUser>>(
      AdminUsersController.new,
      retry: _noAutomaticRetry,
    );

class AdminUsersController extends AdminListController<AdminUser> {
  @override
  Future<AdminPage<AdminUser>> fetch(
    AdminRepository repository,
    AdminPageRequest request,
  ) => repository.users(request);
}

/// The privileged-action log.
final adminAuditEventsProvider =
    AsyncNotifierProvider<AdminAuditEventsController, AdminPage<AuditEvent>>(
      AdminAuditEventsController.new,
      retry: _noAutomaticRetry,
    );

class AdminAuditEventsController extends AdminListController<AuditEvent> {
  @override
  Future<AdminPage<AuditEvent>> fetch(
    AdminRepository repository,
    AdminPageRequest request,
  ) => repository.auditEvents(request);
}

/// Tutor competencies, including the ones awaiting review.
final adminCompetenciesProvider =
    AsyncNotifierProvider<
      AdminCompetenciesController,
      AdminPage<AdminCompetency>
    >(AdminCompetenciesController.new, retry: _noAutomaticRetry);

class AdminCompetenciesController extends AdminListController<AdminCompetency> {
  CompetencyStatus? _status;

  /// The status the queue is narrowed to, or null for every status.
  CompetencyStatus? get status => _status;

  /// Narrows the queue to [status], or widens it again with null.
  ///
  /// Held here rather than in the widget so that the filter the request was sent
  /// with and the filter the control shows are the same value, and so a rebuild
  /// cannot show one while fetching the other.
  void showStatus(CompetencyStatus? status) {
    if (status == _status) return;
    _status = status;
    showFirstPage();
  }

  @override
  Future<AdminPage<AdminCompetency>> fetch(
    AdminRepository repository,
    AdminPageRequest request,
  ) => repository.competencies(request, status: _status);
}

/// Tutor standings and rating aggregates.
final adminTutorStandingsProvider =
    AsyncNotifierProvider<
      AdminTutorStandingsController,
      AdminPage<AdminTutorStanding>
    >(AdminTutorStandingsController.new, retry: _noAutomaticRetry);

class AdminTutorStandingsController
    extends AdminListController<AdminTutorStanding> {
  @override
  Future<AdminPage<AdminTutorStanding>> fetch(
    AdminRepository repository,
    AdminPageRequest request,
  ) => repository.tutorStandings(request);
}

/// Riverpod's default retry re-issues a failed fetch up to ten times with an
/// exponential backoff, which is wrong in both directions for this console: a
/// request that failed on authorisation fails identically every time, and one
/// that failed on the network should surface so the operator can decide to
/// press Retry rather than watch a spinner for half a minute.
Duration? _noAutomaticRetry(int retryCount, Object error) => null;
