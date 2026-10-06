import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/competencies_screen.dart';
import 'package:peerpass_admin/features/admin/presentation/widgets/rejection_reason_dialog.dart';

import '../../../../support/fake_admin_repository.dart';
import '../../../../support/fixtures.dart';

const _session = AdminSession(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  email: 'operator@peerpass.test',
);

/// A signed-in console backed by [repository].
///
/// The surface is deliberately wide. The record table's actions column is the
/// widest thing on screen, and on a narrower surface it is laid out past the
/// scroll viewport's clip: the buttons are then laid out at coordinates the
/// tap misses, so a test would fail on geometry rather than on behaviour.
Future<ProviderContainer> _pump(
  WidgetTester tester,
  FakeAdminRepository repository, {
  Size size = const Size(2400, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer.test(
    // One override, the repository contract the console's lists and writes
    // both read: signing in supplies the session, so a screen test does not
    // have to stand up a token exchange to reach a table.
    overrides: [adminRepositoryProvider.overrideWithValue(repository)],
  );
  container.read(sessionProvider.notifier).signedIn(_session);
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAdminTheme(),
        // A Scaffold, because the screen is a panel inside the console's shell
        // rather than a route of its own, and the pager's dropdown needs a
        // Material ancestor.
        home: const Scaffold(body: CompetenciesScreen()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  return container;
}

/// A refused request carrying the problem document the API sends.
DioException _problem(int status, Object? body) => DioException(
  requestOptions: RequestOptions(path: '/v1/admin/competencies/c1/review'),
  type: DioExceptionType.badResponse,
  response: Response<dynamic>(
    requestOptions: RequestOptions(path: '/v1/admin/competencies/c1/review'),
    statusCode: status,
    data: body,
  ),
);

Future<void> _openRejectionDialog(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Reject'));
  await tester.pumpAndSettle();
}

void main() {
  group('a review in flight', () {
    testWidgets('a second tap does not send a second decision', (tester) async {
      // The write has no idempotency key, so a second tap while the first is
      // waiting records a second decision for a record the server has already
      // moved on from. The buttons are gone for the row while it is busy, so
      // there is nothing left to tap.
      final gate = Completer<void>();
      final repository = _GatedAdminRepository(gate);
      await _pump(tester, repository);

      expect(find.text('Verify'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Verify'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Mid-flight: the row offers neither action and shows that it is working.
      expect(find.text('Verify'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(repository.reviews, hasLength(1));
    });

    testWidgets('the buttons come back when the review failed', (tester) async {
      // Nothing was recorded, so the operator's only way to record it is to try
      // again. Leaving the row permanently busy would strand it.
      final repository =
          FakeAdminRepository(competencyRows: [competencyFixture()])
            ..reviewError = _problem(422, {
              'status': 422,
              'detail': 'A rejection reason is required.',
            });
      await _pump(tester, repository);

      await tester.tap(find.widgetWithText(TextButton, 'Verify'));
      await tester.pumpAndSettle();

      expect(find.text('A rejection reason is required.'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
    });

    testWidgets('a refused verification does not report success', (
      tester,
    ) async {
      // The controller threw where the old one returned an outcome enum. A caller
      // that forgot to check it would have shown "Competency verified." over a
      // record the API never accepted.
      final repository =
          FakeAdminRepository(competencyRows: [competencyFixture()])
            ..reviewError = _problem(422, {
              'status': 422,
              'detail': 'This grade is below the competency threshold.',
              'errors': {'status': 'requires 4.5 or higher on the MUST scale'},
            });
      await _pump(tester, repository);

      await tester.tap(find.widgetWithText(TextButton, 'Verify'));
      await tester.pumpAndSettle();

      expect(find.text('Competency verified.'), findsNothing);
      // The whole message, because `find.text` matches all of it: the detail
      // alone would pass whether or not the threshold reached the operator, and
      // the threshold is the only part the console could not have known.
      expect(
        find.text(
          'This grade is below the competency threshold.\n\n'
          'status: requires 4.5 or higher on the MUST scale',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an expired session is reported as one', (tester) async {
      final repository = FakeAdminRepository(
        competencyRows: [competencyFixture()],
      )..reviewError = _problem(401, {'status': 401});
      await _pump(tester, repository);

      await tester.tap(find.widgetWithText(TextButton, 'Verify'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sign in again'), findsOneWidget);
      expect(
        find.text('Could not record the review. Try again.'),
        findsNothing,
      );
    });

    testWidgets('a decided competency offers no actions', (tester) async {
      // The API owns the transition, so buttons on a verified row would be
      // controls that cannot succeed.
      final repository = FakeAdminRepository(
        competencyRows: [competencyFixture(status: 'verified')],
      );
      await _pump(tester, repository);

      expect(find.text('Verify'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    });
  });

  group('rejecting a competency', () {
    testWidgets('the reason is required before the dialog will close', (
      tester,
    ) async {
      // Previously the dialog returned an empty string and the screen dropped it,
      // so an operator who tapped Reject and left the field blank got no message
      // at all -- indistinguishable from having cancelled.
      final repository = FakeAdminRepository(
        competencyRows: [competencyFixture()],
      );
      await _pump(tester, repository);

      await _openRejectionDialog(tester);

      final reject = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Reject'),
      );
      expect(reject.onPressed, isNull);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Reject'))
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byType(TextField),
        'The transcript is missing.',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Reject'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('the reason typed is the reason sent, trimmed', (tester) async {
      final repository = FakeAdminRepository(
        competencyRows: [competencyFixture()],
      );
      await _pump(tester, repository);

      await _openRejectionDialog(tester);
      await tester.enterText(
        find.byType(TextField),
        '  The transcript does not name the course.  ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
      await tester.pumpAndSettle();

      expect(repository.reviews.single.status, 'rejected');
      expect(
        repository.reviews.single.reason,
        'The transcript does not name the course.',
      );
      expect(find.text('Competency rejected.'), findsOneWidget);
    });

    testWidgets('cancelling sends nothing and says nothing', (tester) async {
      // A deliberate cancellation is not a failure, so it gets no snack bar. It
      // must also not reach the API.
      final repository = FakeAdminRepository(
        competencyRows: [competencyFixture()],
      );
      await _pump(tester, repository);

      await _openRejectionDialog(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repository.reviews, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Verify'), findsOneWidget);
    });

    testWidgets('the field cannot be filled past the API limit', (
      tester,
    ) async {
      // Told here rather than as a 422 the operator cannot predict. The server
      // still owns the rule; this only avoids the round trip.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAdminTheme(),
          home: const Scaffold(body: RejectionReasonDialog()),
        ),
      );

      expect(
        RejectionReasonDialog.maxReasonLength,
        lessThanOrEqualTo(500),
        reason: 'must not be looser than the API',
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.maxLength != null,
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping Reject in the dialog explains an empty answer', (
      tester,
    ) async {
      // Belt and braces: the button is disabled, but the keyboard's done key can
      // still reach _submit, and a silent no-op there would be the old bug.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAdminTheme(),
          home: const Scaffold(body: RejectionReasonDialog()),
        ),
      );

      await tester.enterText(find.byType(TextField), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.textContaining('A reason is required'), findsOneWidget);
      expect(find.byType(RejectionReasonDialog), findsOneWidget);
    });
  });

  group('the queue as a whole', () {
    testWidgets('opens unfiltered', (tester) async {
      final repository = FakeAdminRepository(
        competencyRows: <AdminCompetency>[
          competencyFixture(id: 'c1'),
          competencyFixture(id: 'c2', status: 'rejected'),
        ],
      );

      await _pump(tester, repository);

      // Omitting the filter is every status. Opening on a filtered view would
      // hide work without saying so.
      expect(find.text('All statuses'), findsOneWidget);
      expect(repository.competencyFilters.last, isNull);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Rejected'), findsOneWidget);
    });

    testWidgets('narrows to one status when the operator asks', (tester) async {
      final repository = FakeAdminRepository(
        competencyRows: <AdminCompetency>[
          competencyFixture(id: 'c1'),
          competencyFixture(id: 'c2', status: 'rejected', name: 'Retry Tutor'),
        ],
      );

      await _pump(tester, repository);

      await tester.tap(find.text('All statuses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rejected').last);
      await tester.pumpAndSettle();

      // Asked of the server, so the count the pager shows is the count of rows
      // that actually match.
      expect(repository.competencyFilters.last, CompetencyStatus.rejected);
      expect(find.text('Retry Tutor'), findsOneWidget);
      expect(find.text('Grace Tutor'), findsNothing);
    });

    testWidgets('says which question an empty filtered queue answers', (
      tester,
    ) async {
      final repository = FakeAdminRepository();

      await _pump(tester, repository);

      // Not the console-wide "No records yet.": an operator who has just worked
      // the pending queue to empty has not discovered anything is broken, and
      // the message has to say which question they are looking at.
      expect(find.text('No competencies submitted yet.'), findsOneWidget);

      await tester.tap(find.text('All statuses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Verified').last);
      await tester.pumpAndSettle();

      expect(find.text('No verified competencies.'), findsOneWidget);
    });

    testWidgets('returns to the first page when the filter changes', (
      tester,
    ) async {
      final repository = FakeAdminRepository(
        competencyRows: <AdminCompetency>[
          for (var index = 0; index < 60; index++)
            competencyFixture(id: 'c$index'),
        ],
      );

      await _pump(tester, repository);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(repository.competencyRequests.last.page, 2);

      await tester.tap(find.text('All statuses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rejected').last);
      await tester.pumpAndSettle();

      // Staying on page 3 of a queue that now matches one row would show an
      // empty window, and an operator would read that as "I cleared the queue".
      expect(repository.competencyRequests.last.page, 1);
    });
  });

  group('one row', () {
    testWidgets('shows the bar its grade has to clear and the verdict', (
      tester,
    ) async {
      await _pump(
        tester,
        FakeAdminRepository(
          competencyRows: <AdminCompetency>[competencyFixture()],
        ),
      );

      // The bar, so a decision is not a guess, and the verdict, so the gate is
      // not discovered by being refused.
      expect(find.text('B+ (4.30) against a 4.50 bar'), findsOneWidget);
      expect(find.text('Clears the bar.'), findsOneWidget);
    });

    testWidgets('warns that a grade under the bar cannot be verified', (
      tester,
    ) async {
      await _pump(
        tester,
        FakeAdminRepository(
          competencyRows: <AdminCompetency>[
            competencyFixture(
              gradeLabel: 'B',
              gradePoints: '4.00',
              meetsThreshold: false,
            ),
          ],
        ),
      );

      // Said plainly, because the API refuses it: an operator who finds out
      // afterwards has already read the evidence and made the call.
      expect(find.text('B (4.00) against a 4.50 bar'), findsOneWidget);
      expect(
        find.text('Below the bar: verifying this will be refused.'),
        findsOneWidget,
      );
    });

    testWidgets('explains a missing grading scale rather than showing a ratio', (
      tester,
    ) async {
      await _pump(
        tester,
        FakeAdminRepository(
          competencyRows: <AdminCompetency>[
            competencyFixture(competencyMinPoints: null),
          ],
        ),
      );

      // A faculty whose university has no scale loaded is a normal state, not a
      // fault -- but nothing here can be verified, so the row has to say so.
      expect(find.text('against a '), findsNothing);
      expect(find.textContaining('No grading scale loaded'), findsOneWidget);
    });

    testWidgets('shows why the last review refused it', (tester) async {
      await _pump(
        tester,
        FakeAdminRepository(
          competencyRows: <AdminCompetency>[
            competencyFixture(
              status: 'rejected',
              rejectionReason: 'The transcript page is missing.',
            ),
          ],
        ),
      );

      // The same string the tutor was given. An operator about to refuse again
      // needs to know what the tutor has already been told.
      expect(find.text('The transcript page is missing.'), findsOneWidget);
    });

    testWidgets('shows when it was submitted', (tester) async {
      await _pump(
        tester,
        FakeAdminRepository(
          competencyRows: <AdminCompetency>[
            competencyFixture(submittedAt: '2026-03-04T10:30:00Z'),
          ],
        ),
      );

      // The queue is ordered by this and it is how long the tutor has waited.
      expect(find.text('2026-03-04'), findsOneWidget);
    });

    testWidgets(
      'shows a status this build does not know as the server spelled it',
      (tester) async {
        await _pump(
          tester,
          FakeAdminRepository(
            competencyRows: <AdminCompetency>[
              competencyFixture(status: 'awaiting_registry'),
            ],
          ),
        );

        // A newer API may legitimately have added a state. Blanking the cell would
        // leave an operator unable to say what they are looking at.
        expect(find.text('awaiting_registry'), findsOneWidget);
        // And it is not offered as reviewable: this client cannot know what
        // allows the transition, and the server owns it.
        expect(find.widgetWithText(TextButton, 'Verify'), findsNothing);
      },
    );
  });
}

/// A repository whose review waits until its gate completes, so a test can
/// observe the row while a write is in flight.
class _GatedAdminRepository extends FakeAdminRepository {
  _GatedAdminRepository(this._gate)
    : super(competencyRows: <AdminCompetency>[competencyFixture()]);

  final Completer<void> _gate;

  @override
  Future<void> reviewCompetency(
    AdminCompetency competency,
    String status, {
    String? reason,
  }) async {
    await super.reviewCompetency(competency, status, reason: reason);
    await _gate.future;
  }
}
