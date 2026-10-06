import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_data_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_list_controller.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_data_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_pagination_bar.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_card.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_record_table.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/admin_status_chip.dart';

import '../../../../support/fake_admin_repository.dart';
import '../../../../support/fixtures.dart';
import '../../../../support/semantics.dart';

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
                row: (user) => [
                  adminCell(user.email),
                  adminCell(user.name ?? '—'),
                  adminCell(user.roles.join(', ')),
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
    // Label and value read as one phrase, not as two loose cells. Asserted
    // through the semantics tree rather than through `find.text`, because the
    // phrase is what a screen reader is given and the two have to be the same
    // thing: two visually adjacent Text widgets say nothing to one.
    // `ensureSemantics` because the assertion is about what is announced, and
    // the tree only exists while somebody is asking for it. Disposed at the end
    // of the body rather than in `addTearDown`: the framework asserts that no
    // handle is still active when the test ends, which runs first.
    final semantics = tester.ensureSemantics();

    // Label and value are announced as one phrase. Asserted through the
    // semantics tree rather than through `find.text`, because the phrase is what
    // a screen reader is given and the visible layout is not: two adjacent Text
    // widgets say nothing to one, and a card that only *looks* labelled is the
    // regression this guards against.
    // One node per field, each reading its heading before its value, which is
    // what lets an operator move through a record field by field rather than
    // hearing a whole row at once.
    expect(
      announcedLabels(tester, find.byType(AdminRecordCard)),
      containsAll(<String>[
        'Email: 0ada@peerpass.test',
        'Name: ada lovelace 0',
        'Roles: student',
      ]),
    );
    // And the column headings are still visible, not semantics-only.
    expect(find.text('Email'), findsOneWidget);

    expect(find.text('Showing 1-1 of 1'), findsOneWidget);
    // Nothing was asked to scroll sideways.
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('announces every field of a record on a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminDataTable<String>(
            title: 'Competency review',
            subtitle: 'sub',
            page: const AsyncValue<AdminPage<String>>.data(
              AdminPage<String>(
                items: <String>['c1'],
                total: 1,
                limit: 50,
                offset: 0,
              ),
            ),
            controller: _StubListController(),
            columns: const ['Tutor', 'Status', 'Reason'],
            // Two of these three are widgets with no text of their own, which is
            // the case the review queue is in.
            row: (item) => <Widget>[
              adminCell('Grace Tutor'),
              const AdminStatusChip(
                CompetencyStatus.rejected,
                label: 'Rejected',
              ),
              const AdminRowNote('Page missing.', icon: Icons.block_outlined),
            ],
            spokenRow: (item) => const <String>[
              'Grace Tutor',
              'Rejected',
              'Page missing.',
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();

    // Every field, not just the one that happened to be plain text. An operator
    // working the queue from a phone is deciding on the status and the reason;
    // hearing a heading with nothing after it is worse than not being offered
    // the card at all.
    expect(
      announcedLabels(tester, find.byType(AdminRecordCard)),
      containsAll(<String>[
        'Tutor: Grace Tutor',
        'Status: Rejected',
        'Reason: Page missing.',
      ]),
    );
    semantics.dispose();
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

/// A pager that satisfies the table's contract without a repository.
///
/// The card test is about how a record is announced, so it drives the table
/// directly rather than standing up a signed-in console and a fake list. Its
/// `build` is never run -- nothing listens to it, and the page is handed to the
/// table as data.
class _StubListController extends AdminListController<String> {
  @override
  Future<AdminPage<String>> fetch(
    AdminRepository repository,
    AdminPageRequest request,
  ) async => const AdminPage<String>(
    items: <String>['c1'],
    total: 1,
    limit: 50,
    offset: 0,
  );
}
