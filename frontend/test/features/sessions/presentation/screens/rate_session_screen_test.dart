import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/sessions/data/models/rating_model.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/data/repositories/fake_sessions_repository.dart';
import 'package:peerpass/features/sessions/data/repositories/sessions_repository.dart';
import 'package:peerpass/features/sessions/presentation/screens/rate_session_screen.dart';

const UserProfile _tutee = UserProfile(
  publicId: 'student-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
);

const UserProfile _tutor = UserProfile(
  publicId: 'tutor-1',
  email: 'tutor@must.ac.ug',
  fullName: 'Daniel Okot',
  roles: <UserRole>{UserRole.student, UserRole.tutor},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 3,
);

const String _sessionId = 'session-1';

SessionModel completed({bool isRated = false}) {
  return SessionModel.fromJson({
    'id': _sessionId,
    'tutee_id': _tutee.publicId,
    'tutor_id': _tutor.publicId,
    'course_unit_id': 'unit-1',
    'course_unit_code': 'MAT 221',
    'course_unit_name': 'Linear Algebra',
    'tutee_name': 'Adongo Sarah',
    'tutor_name': 'Okello Daniel',
    'topic': 'Second order ODEs',
    'status': 'completed',
    'duration_minutes': 60,
    'is_rated': isRated,
    'created_at': '2026-03-01T08:00:00Z',
    'scheduled_start': '2026-03-04T09:00:00Z',
    'ended_at': '2026-03-04T10:00:00Z',
    'session_pin': '42',
  });
}

/// A container holding [repository], signed in as [profile].
///
/// The rating screen reads the session through the detail provider, so the
/// session has to be in the repository for the form to appear at all.
ProviderContainer _container(
  FakeSessionsRepository repository,
  UserProfile profile,
) {
  final container = ProviderContainer(
    overrides: [
      sessionsRepositoryProvider.overrideWithValue(repository),
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(session: profile, refreshToken: 'refresh'),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(profile);
  return container;
}

/// A router with the rate screen pushed on top of a stub page.
///
/// The screen pops itself once a rating is accepted, so it needs something to pop
/// *to*. In the app the detail screen pushes this route on top of itself; the test
/// does the same, through the same [AppRoutes.rateSessionPath] helper, so a broken
/// path shows up here rather than only in the app.
Future<FakeSessionsRepository> _pumpRate(
  WidgetTester tester,
  UserProfile profile, {
  FakeSessionsRepository? repository,
}) async {
  final sessions =
      repository ?? FakeSessionsRepository(sessions: [completed()]);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const Scaffold()),
      GoRoute(
        path: '${AppRoutes.sessions}/:sessionId/rate',
        builder: (context, state) => RateSessionScreen(
          sessionId: state.pathParameters['sessionId'] ?? _sessionId,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container(sessions, profile),
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  unawaited(router.push(AppRoutes.rateSessionPath(_sessionId)));
  await _settle(tester);
  return sessions;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

/// A repository that refuses the rating, the way an out-of-range score or a
/// session the API will not accept is refused.
class _RefusingSessionsRepository extends FakeSessionsRepository {
  _RefusingSessionsRepository({super.sessions});

  @override
  Future<RatingModel> rateSession({
    required String sessionId,
    required int score,
    String? feedbackText,
    List<String> endorsedCourseUnitIds = const [],
  }) async {
    throw const ValidationFailure(
      'A session can only be rated once it has finished.',
      fieldErrors: {'session_id': 'not completed'},
    );
  }
}

void main() {
  testWidgets('a score is required, and nothing else is', (tester) async {
    final sessions = await _pumpRate(tester, _tutee);

    // The one field that cannot be left out, so the button stays disabled rather
    // than failing on tap.
    final submit = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(submit.onPressed, isNull);

    await tester.tap(find.bySemanticsLabel('4 of 5'));
    await _settle(tester);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );

    await tester.tap(find.byType(FilledButton));
    await _settle(tester);

    expect(sessions.submittedRatings.single.score, 4);
  });

  testWidgets('the note goes out as written, and a blank one is not sent', (
    tester,
  ) async {
    final sessions = await _pumpRate(tester, _tutee);

    await tester.tap(find.bySemanticsLabel('5 of 5'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Explained it twice. ');
    await _settle(tester);
    await tester.tap(find.byType(FilledButton));
    await _settle(tester);

    // Trimmed on the way out. The surrounding whitespace is the phone keyboard's,
    // not something the student meant to say.
    expect(
      sessions.submittedRatings.single.feedbackText,
      'Explained it twice.',
    );

    final second = FakeSessionsRepository(sessions: [completed()]);
    await _pumpRate(tester, _tutee, repository: second);
    await tester.tap(find.bySemanticsLabel('3 of 5'));
    await _settle(tester);
    await tester.tap(find.byType(FilledButton));
    await _settle(tester);

    // A blank note is the absence of a note. Sending `''` would assert that the
    // field is empty, which is a different claim and would clear a stored one on
    // a re-submission.
    expect(second.submittedRatings.single.feedbackText, isNull);
  });

  group('the endorsement', () {
    testWidgets('is off by default, and off means nothing is endorsed', (
      tester,
    ) async {
      final sessions = await _pumpRate(tester, _tutee);

      final checkbox = tester.widget<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(checkbox.value, isFalse);

      await tester.tap(find.bySemanticsLabel('5 of 5'));
      await _settle(tester);
      await tester.tap(find.byType(FilledButton));
      await _settle(tester);

      // A student who wants to leave a mark and go is not made to assert a claim
      // about a tutor's coverage to get past a form. That is the failure the API
      // documents this field as guarding against.
      expect(sessions.endorsementSubmissions.single, isEmpty);
    });

    testWidgets('names the session own unit when it is ticked', (tester) async {
      final sessions = await _pumpRate(tester, _tutee);

      await tester.tap(find.byType(CheckboxListTile));
      await _settle(tester);
      await tester.tap(find.bySemanticsLabel('5 of 5'));
      await _settle(tester);
      await tester.tap(find.byType(FilledButton));
      await _settle(tester);

      // Exactly the unit the session was booked for. The API's service refuses any
      // other unit, so a list of units to pick from would be a list where every
      // choice but this one is rejected by the server.
      expect(sessions.endorsementSubmissions.single, ['unit-1']);
    });

    testWidgets('is not offered to a tutor, who has no tutor to endorse', (
      tester,
    ) async {
      // The API derives the ratee from the session and writes the endorsement to
      // that ratee's tutor record. A tutor rating a student would be recorded as
      // a tutor endorsing a student, which is not what the field means.
      await _pumpRate(tester, _tutor);

      expect(find.byType(CheckboxListTile), findsNothing);
    });
  });

  testWidgets('a refused rating keeps the draft and says why', (tester) async {
    await _pumpRate(
      tester,
      _tutee,
      repository: _RefusingSessionsRepository(sessions: [completed()]),
    );

    await tester.tap(find.bySemanticsLabel('5 of 5'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Worth saying.');
    await _settle(tester);
    await tester.tap(find.byType(FilledButton));
    await _settle(tester);

    // The screen stays open and the note survives, so fixing the problem does not
    // mean retyping. The failure's own message, never the exception.
    expect(
      find.text('A session can only be rated once it has finished.'),
      findsOneWidget,
    );
    expect(find.text('Worth saying.'), findsOneWidget);
  });

  testWidgets('a session with a rating already offers to replace it', (
    tester,
  ) async {
    await _pumpRate(
      tester,
      _tutee,
      repository: FakeSessionsRepository(sessions: [completed(isRated: true)]),
    );

    // `POST /v1/ratings/{session_id}` updates in place rather than adding a second
    // rating, so the screen says what sending will do instead of implying there is
    // a second score to give.
    expect(find.text('Submit rating'), findsNothing);
    expect(find.text('Update rating'), findsOneWidget);
  });

  testWidgets('correcting a rating warns that an untouched box withdraws', (
    tester,
  ) async {
    // The API replaces `endorsed_course_unit_ids` on every submission, and an
    // empty list withdraws what the rater endorsed before. `RatingResponse` does
    // not echo a rater's own endorsements, so the client cannot start the box out
    // ticked to match -- the user is told instead of losing the claim quietly.
    await _pumpRate(
      tester,
      _tutee,
      repository: FakeSessionsRepository(sessions: [completed(isRated: true)]),
    );

    expect(find.textContaining('withdraws the recommendation'), findsOneWidget);
  });

  testWidgets('a first rating cannot be dismissed', (tester) async {
    await _pumpRate(tester, _tutee);

    expect(
      find.text('A rating is required to finish this session review.'),
      findsOneWidget,
    );
    expect(find.text('Not now'), findsNothing);
  });
}
