import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_pagination_bar.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_card.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';

import '../../../../support/fake_admin_repository.dart';
import '../../../../support/fixtures.dart';

void main() {
  late FakeAdminRepository repository;

  /// A signed-in console with [users] rows, ready to pump.
  ProviderContainer signedInConsole(List<AdminUser> users) {
    repository = FakeAdminRepository(userRows: users);
    final container = ProviderContainer.test(
      overrides: [adminRepositoryProvider.overrideWithValue(repository)],
    );
    container
        .read(sessionProvider.notifier)
        .signedIn(
          const AdminSession(
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
            email: 'operator@peerpass.test',
          ),
        );
    return container;
  }

  /// The users list as the console renders it.
  Future<void> pumpUsersList(
    WidgetTester tester,
    ProviderContainer container, {
    Size window = const Size(1280, 900),
  }) async {
    await tester.binding.setSurfaceSize(window);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, child) => AdminDataTable<AdminUser>(
                title: 'Users',
                subtitle: 'Every account on the network.',
                page: ref.watch(adminUsersProvider),
                controller: ref.read(adminUsersProvider.notifier),
                columns: const <String>['Email', 'Name', 'Roles'],
                row: (user) => <String>[
                  user.email,
                  user.name ?? '—',
                  user.roles.join(', '),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<AdminUser> usersNamed(String first, String last, {int count = 1}) => [
    for (var index = 0; index < count; index++)
      adminUserFixture(
        email: '$index$first@peerpass.test',
        name: '$first $last $index',
      ),
  ];

  testWidgets('shows the first page of a list', (tester) async {
    final semantics = tester.ensureSemantics();
    final container = signedInConsole(usersNamed('ada', 'lovelace', count: 2));

    await pumpUsersList(tester, container);

    expect(find.text('0ada@peerpass.test'), findsOneWidget);
    expect(find.text('1ada@peerpass.test'), findsOneWidget);
    expect(find.text('Showing 1-2 of 2'), findsOneWidget);
    expect(find.text('Page 1 of 1'), findsOneWidget);
    // A page change is announced rather than swapped under the reader.
    expect(
      tester
          .getSemantics(find.byType(AdminPaginationBar<AdminUser>))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );

    semantics.dispose();
  });

  testWidgets('asks for the next page and shows the rows it left out', (
    tester,
  ) async {
    final container = signedInConsole([
      for (var index = 0; index < 51; index++)
        adminUserFixture(email: '$index@peerpass.test'),
    ]);

    await pumpUsersList(tester, container);
    expect(find.text('Showing 1-50 of 51'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Next'));
    await tester.pumpAndSettle();

    expect(repository.userRequests.last.offset, 50);
    expect(find.text('Showing 51-51 of 51'), findsOneWidget);
    expect(find.text('50@peerpass.test'), findsOneWidget);
    expect(find.text('0@peerpass.test'), findsNothing);
    expect(find.text('Page 2 of 2'), findsOneWidget);
  });

  testWidgets('disables Next on the last page', (tester) async {
    final container = signedInConsole(usersNamed('ada', 'lovelace'));

    await pumpUsersList(tester, container);

    final next = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Next'),
    );
    final previous = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Previous'),
    );
    expect(next.onPressed, isNull);
    expect(previous.onPressed, isNull);
  });

  testWidgets('goes back a page', (tester) async {
    final container = signedInConsole([
      for (var index = 0; index < 120; index++)
        adminUserFixture(email: '$index@peerpass.test'),
    ]);

    await pumpUsersList(tester, container);
    await tester.tap(find.widgetWithText(TextButton, 'Next'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 3'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Previous'));
    await tester.pumpAndSettle();

    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.text('Showing 1-50 of 120'), findsOneWidget);
  });

  testWidgets('says so when a list holds no records', (tester) async {
    final container = signedInConsole(const <AdminUser>[]);

    await pumpUsersList(tester, container);

    expect(find.text('No records yet.'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(repository.userRequests, hasLength(1));
  });

  testWidgets('shows records as labelled cards in a narrow window', (
    tester,
  ) async {
    final container = signedInConsole(usersNamed('ada', 'lovelace'));

    await pumpUsersList(tester, container, window: const Size(420, 900));

    expect(find.byType(AdminRecordCard), findsOneWidget);
    expect(find.byType(AdminRecordTable), findsNothing);
    // Label and value read as one phrase, not as two loose cells.
    expect(find.textContaining('Email  0ada@peerpass.test'), findsOneWidget);
    expect(find.text('Showing 1-1 of 1'), findsOneWidget);
    // Nothing was asked to scroll sideways.
    expect(tester.takeException(), isNull);
  });

  testWidgets('re-reads a failed list when the retry is pressed', (
    tester,
  ) async {
    final container = signedInConsole(usersNamed('ada', 'lovelace'));
    repository.listError = StateError('the read failed');

    await pumpUsersList(tester, container);
    expect(find.text('Could not load this view.'), findsOneWidget);

    repository.listError = null;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.text('0ada@peerpass.test'), findsOneWidget);
    expect(find.text('Could not load this view.'), findsNothing);
  });

  testWidgets('reads an empty page without asking the API again', (
    tester,
  ) async {
    final container = signedInConsole(const <AdminUser>[]);

    await pumpUsersList(tester, container);
    final before = repository.userRequests.length;
    await tester.pump();

    expect(repository.userRequests, hasLength(before));
    expect(find.text('No records yet.'), findsOneWidget);
  });

  testWidgets(
    'a list is not re-read when the page it holds is asked for again',
    (tester) async {
      final container = signedInConsole(usersNamed('ada', 'lovelace'));

      await pumpUsersList(tester, container);
      container
          .read(adminUsersProvider.notifier)
          .show(const AdminPageRequest());
      await tester.pumpAndSettle();

      expect(repository.userRequests, hasLength(1));
    },
  );
}
