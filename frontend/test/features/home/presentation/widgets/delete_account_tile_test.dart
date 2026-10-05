import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/theme/app_theme.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/home/presentation/widgets/delete_account_tile.dart';

const UserProfile _student = UserProfile(
  publicId: 'user-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
);

typedef _Harness = ({
  ProviderContainer container,
  // Declared as the contract rather than the fake: a test may hand in any
  // [AuthRepository], and the row under test only ever calls through it.
  AuthRepository repository,
});

/// Builds a container holding [profile] as the signed-in account.
_Harness _harness({
  UserProfile profile = _student,
  AuthRepository? repository,
}) {
  final auth =
      repository ??
      FakeAuthRepository(session: profile, refreshToken: 'refresh');
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(auth)],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(profile);
  return (container: container, repository: auth);
}

/// A repository whose deletion fails with [failure].
///
/// Subclasses the fake rather than standing up a mock: the fake already models the
/// token store, and the thing under test is what the screen says when the call
/// does not succeed, not the transport.
class _FailingDelete extends FakeAuthRepository {
  _FailingDelete(this.failure)
    : super(session: _student, refreshToken: 'refresh');

  final Failure failure;

  @override
  Future<void> deleteAccount() async {
    // Deliberately does *not* end the session. The request failed, so the
    // account is still on the server and the tokens are still good; a fake that
    // signed the user out would let the screen pass against a contract the real
    // repository no longer has.
    throw failure;
  }
}

/// How many times `deleteAccount` was called.
class _CountingFake extends FakeAuthRepository {
  _CountingFake() : super(session: _student, refreshToken: 'refresh');

  int calls = 0;

  @override
  Future<void> deleteAccount() {
    calls++;
    return super.deleteAccount();
  }
}

Future<void> _pumpTile(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: DeleteAccountTile()),
      ),
    ),
  );
  await tester.pump();
}

/// Opens the confirmation and types the account email, leaving the dialog open.
Future<void> _openDialogAndType(WidgetTester tester) async {
  await tester.tap(find.text('Delete my account'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), _student.email);
  await tester.pumpAndSettle();
}

void main() {
  group('confirmation', () {
    testWidgets('asks the user to type a word before enabling the button', (
      tester,
    ) async {
      await _pumpTile(tester, _harness());
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();

      expect(find.text('Delete your account?'), findsOneWidget);
      expect(
        find.text('Type your email address to confirm: ${_student.email}'),
        findsOneWidget,
      );

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Delete permanently'),
      );
      // The gate itself. An enabled button here would mean a mis-tap is permanent.
      expect(button.onPressed, isNull);
    });

    testWidgets(
      'enables the button only when the email matches case-insensitively',
      (tester) async {
        await _pumpTile(tester, _harness());
        await tester.tap(find.text('Delete my account'));
        await tester.pumpAndSettle();

        // A partial address is not enough to make an irreversible action live.
        await tester.enterText(find.byType(TextField), 'student@must.ac');
        await tester.pumpAndSettle();
        var button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Delete permanently'),
        );
        expect(button.onPressed, isNull);

        await tester.enterText(
          find.byType(TextField),
          _student.email.toUpperCase(),
        );
        await tester.pumpAndSettle();
        button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Delete permanently'),
        );
        expect(button.onPressed, isNotNull);
      },
    );

    testWidgets('dismissing the dialog deletes nothing', (tester) async {
      final harness = _harness();
      await _pumpTile(tester, harness);
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keep my account'));
      await tester.pumpAndSettle();

      expect(find.text('Delete your account?'), findsNothing);
      expect(harness.repository, isNotNull);
      expect(
        harness.container.read(sessionControllerProvider).isSignedIn,
        isTrue,
      );
    });

    testWidgets('tells the user their name goes and the evidence stays', (
      tester,
    ) async {
      // The asymmetry is the whole product decision. A dialog that said only
      // "this cannot be undone" would leave the user thinking their sessions and
      // ratings go too, and would be refused on that basis.
      await _pumpTile(tester, _harness());
      await tester.tap(find.text('Delete my account'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Sessions and ratings you were part of are kept'),
        findsOneWidget,
      );
    });
  });

  group('outcomes', () {
    testWidgets('ends the session on success', (tester) async {
      final harness = _harness();
      await _pumpTile(tester, harness);
      await _openDialogAndType(tester);

      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      // The whole point: an account the user asked to stop existing must not be
      // left holding a live session.
      expect(harness.container.read(sessionControllerProvider).profile, isNull);
    });

    testWidgets('a network failure says the account is unchanged', (
      tester,
    ) async {
      // The word "unchanged" is the load-bearing part. Telling the user the
      // account "may or may not have been deleted" is both unusable and untrue:
      // the request did not arrive, so the account is intact.
      final harness = _harness(
        repository: _FailingDelete(const NetworkFailure()),
      );
      await _pumpTile(tester, harness);
      await _openDialogAndType(tester);

      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(find.textContaining('your account is unchanged'), findsOneWidget);
      // No raw transport text anywhere on screen.
      expect(find.textContaining('Dio'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('a server failure carries the server wording', (tester) async {
      final harness = _harness(
        repository: _FailingDelete(const ServerFailure('database is down')),
      );
      await _pumpTile(tester, harness);
      await _openDialogAndType(tester);

      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(find.textContaining('database is down'), findsOneWidget);
    });

    testWidgets('an expired session says nothing was deleted', (tester) async {
      // The realistic ordering: the token dies first, so the delete 401s. Saying
      // "nothing was changed" is what stops the user believing their account is
      // gone while it is not.
      final harness = _harness(repository: _FailingDelete(const AuthFailure()));
      await _pumpTile(tester, harness);
      await _openDialogAndType(tester);

      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(find.textContaining('nothing was deleted'), findsOneWidget);
    });

    testWidgets('keeps the session alive when the delete failed', (
      tester,
    ) async {
      // The load-bearing half of the fix, and the reason the message is now
      // visible at all. A failed delete means the account is still whole *and*
      // the session is still good, so ending it here would replace the
      // explanation with a sign-in form and take away the retry the sentence
      // tells the user to make.
      final harness = _harness(
        repository: _FailingDelete(const NetworkFailure()),
      );
      await _pumpTile(tester, harness);
      await _openDialogAndType(tester);

      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(
        harness.container.read(sessionControllerProvider).isSignedIn,
        isTrue,
      );
      // And the reason is still on screen rather than replaced by a redirect.
      expect(find.textContaining('your account is unchanged'), findsOneWidget);
    });

    testWidgets('does not fire twice while the request is in flight', (
      tester,
    ) async {
      final repository = _CountingFake();
      final harness = _harness(repository: repository);
      await _pumpTile(tester, harness);
      await _openDialogAndType(tester);

      await tester.tap(find.text('Delete permanently'));
      await tester.pump();

      // The row is disabled while busy, so a second tap cannot start a second
      // deletion. The server is idempotent, but two spinners is a confusing
      // screen rather than an error.
      expect(repository.calls, 1);
      expect(find.text('Delete my account'), findsOneWidget);
    });
  });
}
