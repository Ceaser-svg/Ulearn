import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';

import '../../../../support/fake_admin_repository.dart';
import '../../../../support/fixtures.dart';

const _session = AdminSession(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  email: 'operator@peerpass.test',
);

/// Asserts on how many rows an admin list is holding, naming the list so a
/// failure says which one went wrong.
Future<void> _expectRowCount<T>(
  Future<AdminPage<T>> Function() read,
  String list,
  Matcher rows,
) async {
  expect((await read()).items.length, rows, reason: list);
}

void main() {
  late FakeAdminRepository repository;

  /// A signed-in console backed by [repository].
  ProviderContainer signedInConsole({int users = 3}) {
    repository = FakeAdminRepository(
      userRows: [
        for (var index = 0; index < users; index++)
          adminUserFixture(email: 'user$index@peerpass.test'),
      ],
      auditEventRows: [auditEventFixture(action: 'competency.verified')],
      competencyRows: [competencyFixture()],
      tutorStandingRows: [tutorStandingFixture(email: 'tutor@peerpass.test')],
    );
    final container = ProviderContainer.test(
      overrides: [adminRepositoryProvider.overrideWithValue(repository)],
    );
    container.read(sessionProvider.notifier).signedIn(_session);
    return container;
  }

  group('paging', () {
    test('asks for the first page on the first read', () async {
      final container = signedInConsole(users: 120);

      final page = await container.read(adminUsersProvider.future);

      expect(page.items, hasLength(50));
      expect(page.total, 120);
      expect(page.offset, 0);
      expect(page.hasMore, isTrue);
      expect(page.pageCount, 3);
      expect(repository.userRequests.single, const AdminPageRequest());
    });

    test(
      'asks for the next page, skipping the rows the first one held',
      () async {
        final container = signedInConsole(users: 120);
        await container.read(adminUsersProvider.future);

        container
            .read(adminUsersProvider.notifier)
            .show(const AdminPageRequest(page: 3));

        final page = await container.read(adminUsersProvider.future);
        expect(page.offset, 100);
        expect(page.items, hasLength(20));
        expect(page.hasMore, isFalse);
        expect(page.firstRowNumber, 101);
        expect(page.lastRowNumber, 120);
        expect(repository.userRequests.last.offset, 100);
      },
    );

    test('a different page size starts again at the first page', () async {
      final container = signedInConsole(users: 120);
      await container.read(adminUsersProvider.future);
      container
          .read(adminUsersProvider.notifier)
          .show(const AdminPageRequest(page: 3));

      container
          .read(adminUsersProvider.notifier)
          .show(const AdminPageRequest(limit: 10));

      final page = await container.read(adminUsersProvider.future);
      expect(page.limit, 10);
      expect(page.offset, 0);
      expect(page.pageCount, 12);
    });

    test('re-reads the current page when refreshed', () async {
      final container = signedInConsole(users: 120);
      await container.read(adminUsersProvider.future);

      container.read(adminUsersProvider.notifier).refresh();

      await container.read(adminUsersProvider.future);
      expect(repository.userRequests, hasLength(2));
      expect(repository.userRequests.last, const AdminPageRequest());
    });

    test('does not re-read when asked for the page it already holds', () async {
      final container = signedInConsole();
      await container.read(adminUsersProvider.future);

      container
          .read(adminUsersProvider.notifier)
          .show(const AdminPageRequest());

      await container.read(adminUsersProvider.future);
      expect(repository.userRequests, hasLength(1));
    });

    test('reports an empty page for a list with no rows', () async {
      final container = signedInConsole(users: 0);

      final page = await container.read(adminUsersProvider.future);

      expect(page.items, isEmpty);
      expect(page.total, 0);
      expect(page.pageCount, 0);
    });
  });

  group('signing out', () {
    test('drops the rows a list had already fetched', () async {
      final container = signedInConsole();
      await _expectRowCount(
        () => container.read(adminUsersProvider.future),
        'before',
        isNot(0),
      );

      container.read(sessionProvider.notifier).signOut();

      await _expectRowCount(
        () => container.read(adminUsersProvider.future),
        'users after sign-out',
        isZero,
      );
      // Gone without a second request, because there is nothing left to
      // authorise one.
      expect(repository.userRequests, hasLength(1));
    });

    test('drops the rows every admin list had already fetched', () async {
      final container = signedInConsole();
      await _expectRowCount(
        () => container.read(adminUsersProvider.future),
        'users',
        isNot(0),
      );
      await _expectRowCount(
        () => container.read(adminAuditEventsProvider.future),
        'audit events',
        isNot(0),
      );
      await _expectRowCount(
        () => container.read(adminCompetenciesProvider.future),
        'competencies',
        isNot(0),
      );
      await _expectRowCount(
        () => container.read(adminTutorStandingsProvider.future),
        'tutor standings',
        isNot(0),
      );

      container.read(sessionProvider.notifier).signOut();

      await _expectRowCount(
        () => container.read(adminUsersProvider.future),
        'users after sign-out',
        isZero,
      );
      await _expectRowCount(
        () => container.read(adminAuditEventsProvider.future),
        'audit events after sign-out',
        isZero,
      );
      await _expectRowCount(
        () => container.read(adminCompetenciesProvider.future),
        'competencies after sign-out',
        isZero,
      );
      await _expectRowCount(
        () => container.read(adminTutorStandingsProvider.future),
        'tutor standings after sign-out',
        isZero,
      );
      expect(repository.userRequests, hasLength(1));
      expect(repository.auditEventRequests, hasLength(1));
      expect(repository.competencyRequests, hasLength(1));
      expect(repository.tutorStandingRequests, hasLength(1));
    });

    test('makes no request for a list that was never read', () async {
      final container = signedInConsole();

      container.read(sessionProvider.notifier).signOut();
      await _expectRowCount(
        () => container.read(adminAuditEventsProvider.future),
        'audit events',
        isZero,
      );

      expect(repository.auditEventRequests, isEmpty);
    });

    test('drops the session with the credentials', () async {
      final container = signedInConsole();

      container.read(sessionProvider.notifier).signOut();

      expect(container.read(sessionProvider), isNull);
    });

    test('an expiry the transport reports drops the rows too', () async {
      final container = signedInConsole();
      await container.read(adminUsersProvider.future);

      container.read(sessionProvider.notifier).expired();

      await _expectRowCount(
        () => container.read(adminUsersProvider.future),
        'users after expiry',
        isZero,
      );
      expect(container.read(sessionProvider), isNull);
    });
  });
}
