import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';

/// Holds one admin list and the page of it that is on screen.
///
/// One controller per list rather than one per list-and-page, because an
/// operator reads one page at a time. That keeps the current page in one place
/// where it cannot disagree with the request the next fetch will send, and it
/// keeps the paging arithmetic out of the widget.
///
/// Subclasses supply only the fetch; the session guard, the page arithmetic and
/// the refresh behaviour are identical for every list and live here.
abstract class AdminListController<T> extends AsyncNotifier<AdminPage<T>> {
  AdminPageRequest _request = const AdminPageRequest();

  /// The page this controller is showing, or loading.
  AdminPageRequest get request => _request;

  /// Reads one page of this list from the API.
  Future<AdminPage<T>> fetch(
    AdminRepository repository,
    AdminPageRequest request,
  );

  @override
  Future<AdminPage<T>> build() async {
    final session = ref.watch(sessionProvider);
    if (session == null) {
      return AdminPage<T>.empty();
    }
    return await fetch(ref.watch(adminRepositoryProvider), _request);
  }

  /// Shows a different page.
  ///
  /// The controller is invalidated rather than assigned so that the fetch, the
  /// session guard and any error handling stay the ones `build` already uses.
  void show(AdminPageRequest request) {
    if (request == _request) return;
    _request = request;
    ref.invalidateSelf();
  }

  /// Re-reads the current page, after a review was recorded or an operator
  /// asked a failed list to try again.
  void refresh() => ref.invalidateSelf();
}
