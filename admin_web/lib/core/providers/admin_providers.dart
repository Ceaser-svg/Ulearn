import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/network/admin_api_client.dart';

/// The signed-in administrator, or null when there is none.
///
/// A null session is the console's single definition of "not authenticated".
/// Every screen that reads admin data watches this provider, so clearing it is
/// what takes those screens back to the sign-in view.
final sessionProvider = NotifierProvider<SessionController, AdminSession?>(
  SessionController.new,
);

/// The console's transport, wired to the session it belongs to.
///
/// The two providers live together because they depend on each other: the
/// client has to be able to report an expiry, and the controller has to be
/// able to drop the client's tokens. Split across files that is an import
/// cycle for no gain.
final adminApiClientProvider = Provider<AdminApiClient>(
  (ref) => AdminApiClient(
    baseUrl: _apiBaseUrl,
    dio: ref.watch(adminDioProvider),
    onSessionExpired: () => ref.read(sessionProvider.notifier).expired(),
  ),
);

/// The HTTP stack the console sends through.
///
/// Separate from the client so a test can put a transport in front of it and
/// still exercise the client, the expiry wiring, and the repository exactly as
/// they ship.
final adminDioProvider = Provider<Dio>(
  (ref) => AdminApiClient.buildDio(_apiBaseUrl),
);

const _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

class SessionController extends Notifier<AdminSession?> {
  @override
  AdminSession? build() => null;

  void signedIn(AdminSession session) => state = session;

  /// Ends the session: the credentials go first, then the state.
  ///
  /// Order matters. Clearing the state is what makes the screens read as
  /// signed out, and dropping the tokens calls back into [expired]; setting
  /// the state first means that callback finds nothing to do instead of
  /// re-entering the sign-out it was triggered by.
  ///
  /// Every provider holding admin data watches this one, so a null state
  /// discards those rows rather than leaving fetched records in a UI with no
  /// credentials behind it.
  void signOut() {
    state = null;
    ref.read(adminApiClientProvider).signOut();
  }

  /// Reacts to the console discovering it can no longer authenticate: a
  /// refresh failed, or a rejected request could not be recovered.
  ///
  /// Idempotent on purpose. A burst of in-flight requests can discover the
  /// same expiry at once, and the operator must land on the sign-in view once
  /// rather than on a stack of redundant transitions.
  void expired() {
    if (state == null) return;
    signOut();
  }
}
