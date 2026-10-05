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
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/data/repositories/fake_sessions_repository.dart';
import 'package:peerpass/features/sessions/data/repositories/sessions_repository.dart';
import 'package:peerpass/features/sessions/presentation/screens/session_detail_screen.dart';

/// The student in the sessions below.
const UserProfile _tutee = UserProfile(
  publicId: 'student-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
);

/// The other party, so both sides of the handshake can be driven.
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

SessionModel session({
  String status = 'scheduled',
  bool isRated = false,
  String? meetingLink,
  String? endedAt,
}) {
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
    'status': status,
    'duration_minutes': 60,
    'is_rated': isRated,
    'created_at': '2026-03-01T08:00:00Z',
    'scheduled_start': '2026-03-04T09:00:00Z',
    'started_at': '2026-03-04T09:05:00Z',
    'ended_at': endedAt,
    'meeting_link': meetingLink,
  });
}

/// A container holding [session], signed in as [profile].
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

Future<void> _pumpDetail(
  WidgetTester tester,
  FakeSessionsRepository repository,
  UserProfile profile,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container(repository, profile),
      child: MaterialApp(
        theme: AppTheme.light,
        home: const SessionDetailScreen(sessionId: _sessionId),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

/// A repository whose one session cannot be loaded.
class _MissingSessionRepository extends FakeSessionsRepository {
  @override
  Future<SessionModel> session(String sessionId) async {
    throw const NotFoundFailure('That session could not be found.');
  }
}

void main() {
  group('the record', () {
    testWidgets('names the session and both sides of it', (tester) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session()]),
        _tutee,
      );

      expect(find.text('Second order ODEs'), findsOneWidget);
      // Names, not public ids. This row used to render the other party's
      // public_id because `SessionResponse` carried no display name for either
      // party, which showed a student a UUID instead of the person they were
      // about to meet. The API now projects both names and the unit's code and
      // title beside the ids.
      expect(find.text('Tutor'), findsOneWidget);
      expect(find.text('Okello Daniel'), findsOneWidget);
      expect(find.text(_tutor.publicId), findsNothing);
      expect(find.text('MAT 221 · Linear Algebra'), findsOneWidget);
      expect(find.text('1 hr'), findsOneWidget);
    });

    testWidgets('falls back to the public id when the other party is unnamed', (
      tester,
    ) async {
      // An account can exist without a display name. The row is about
      // identifying a person the reader is about to meet, so it shows the id
      // rather than leaving a labelled row empty -- but it is a fallback, not
      // the normal reading.
      final unnamed = SessionModel(
        id: 'session-1',
        tuteeId: _tutee.publicId,
        tutorId: _tutor.publicId,
        courseUnitId: 'unit-1',
        courseUnitCode: 'MAT 221',
        courseUnitName: 'Linear Algebra',
        topic: 'Second order ODEs',
        statusWire: 'scheduled',
        createdAt: DateTime.utc(2026, 3, 1, 8),
        scheduledStart: DateTime.utc(2026, 3, 2, 9),
        durationMinutes: 60,
      );
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [unnamed]),
        _tutee,
      );

      expect(find.text('Tutor'), findsOneWidget);
      expect(find.text(_tutor.publicId), findsOneWidget);
    });

    testWidgets('a meeting link is copyable rather than tappable', (
      tester,
    ) async {
      // The app ships no link-opening dependency, and the agreed substitute for
      // in-app chat is a value the student hands to a browser.
      await _pumpDetail(
        tester,
        FakeSessionsRepository(
          sessions: [session(meetingLink: 'https://meet.peerpass.test/abc')],
        ),
        _tutee,
      );

      expect(find.byTooltip('Copy meeting link'), findsOneWidget);
      expect(find.text('https://meet.peerpass.test/abc'), findsOneWidget);
    });

    testWidgets('a session that is not there says so and offers another try', (
      tester,
    ) async {
      await _pumpDetail(tester, _MissingSessionRepository(), _tutee);

      expect(
        find.text(
          const NotFoundFailure('That session could not be found.').message,
        ),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('the handshake, from the tutor side', () {
    testWidgets('the PIN is fetched on demand, not held on the session', (
      tester,
    ) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session()]),
        _tutor,
      );

      // Nothing is on screen until asked for. A PIN is read aloud in a room with
      // other people in it, and it is fetched rather than carried on the session
      // because a tutee could otherwise read their own off the same payload.
      expect(find.text('42'), findsNothing);
      expect(find.text('Show PIN'), findsOneWidget);

      await tester.tap(find.text('Show PIN'));
      await _settle(tester);
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('hiding the PIN drops it from the screen', (tester) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session()]),
        _tutor,
      );

      await tester.tap(find.text('Show PIN'));
      await _settle(tester);
      expect(find.text('42'), findsOneWidget);

      await tester.tap(find.text('Hide PIN'));
      await _settle(tester);
      expect(find.text('42'), findsNothing);
    });

    testWidgets('the tutor cannot type the PIN in themselves', (tester) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session()]),
        _tutor,
      );

      // The API only lets the tutee enter it. Offering the field and having the
      // server refuse it would teach a tutor that the app offers things it cannot
      // do, and would invite them to prove nothing by typing digits they read.
      expect(find.widgetWithText(TextField, 'PIN'), findsNothing);
      expect(find.text('Start session'), findsNothing);
    });

    testWidgets('the tutor is warned when the tutee is nearly out of attempts', (
      tester,
    ) async {
      // Four of the five attempts already spent. The advisory is there so a tutor
      // can stop the student guessing in a room where they are trying to learn,
      // rather than watch them burn the last one.
      await _pumpDetail(
        tester,
        FakeSessionsRepository(
          sessions: [session()],
          pinFailures: {_sessionId: 4},
        ),
        _tutor,
      );

      await tester.tap(find.text('Show PIN'));
      await _settle(tester);

      expect(find.text('42'), findsOneWidget);
      expect(find.textContaining('1 attempt left'), findsOneWidget);
    });

    testWidgets('no warning is shown while attempts remain', (tester) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session()]),
        _tutor,
      );

      await tester.tap(find.text('Show PIN'));
      await _settle(tester);

      // Nothing to warn about on a fresh session, so the panel does not cry wolf
      // on every single one.
      expect(find.text('42'), findsOneWidget);
      expect(find.textContaining('attempt'), findsNothing);
    });
  });

  group('the handshake, from the tutee side', () {
    testWidgets('the tutee cannot read their own PIN', (tester) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session()]),
        _tutee,
      );

      // The digits are the tutor's to read out. A tutee who could see their own
      // would have nothing to prove, and the tutor no way to tell an in-person
      // student from someone guessing two digits on a borrowed account.
      expect(find.text('Show PIN'), findsNothing);
      expect(find.text('42'), findsNothing);
      expect(find.widgetWithText(TextField, 'PIN'), findsOneWidget);
    });
  });

  group('entering the PIN, from the tutee side', () {
    testWidgets('the right PIN starts the session', (tester) async {
      final repository = FakeSessionsRepository(sessions: [session()]);
      await _pumpDetail(tester, repository, _tutee);

      await tester.enterText(find.byType(TextField), '42');
      await _settle(tester);
      await tester.tap(find.text('Start session'));
      await _settle(tester);

      expect(repository.pinAttempts, ['42']);
      // The panel changes rather than disappearing: the tutee needs to know the
      // handshake worked, not just that the screen stopped asking.
      expect(find.text('Handshake complete'), findsOneWidget);
    });

    testWidgets('a wrong PIN says what to do, and the session is not started', (
      tester,
    ) async {
      final repository = FakeSessionsRepository(sessions: [session()]);
      await _pumpDetail(tester, repository, _tutee);

      await tester.enterText(find.byType(TextField), '41');
      await _settle(tester);
      await tester.tap(find.text('Start session'));
      await _settle(tester);

      // The pin really was sent rather than refused by the client: the client
      // cannot know it is wrong, and pretending otherwise would hide a genuine
      // mismatch behind a guess.
      expect(repository.pinAttempts, ['41']);
      expect(
        find.text('That is not the right PIN. Ask your tutor to check it.'),
        findsOneWidget,
      );
      expect(find.text('Handshake complete'), findsNothing);
      expect(find.text('Start session'), findsOneWidget);
    });

    testWidgets('a second attempt is still allowed after a refusal', (
      tester,
    ) async {
      // No client-side attempt counter and no lock-out. A student on a bad
      // connection who mistypes must be able to try again, and a lock the device
      // enforces is one they clear by reinstalling the app.
      final repository = FakeSessionsRepository(sessions: [session()]);
      await _pumpDetail(tester, repository, _tutee);

      await tester.enterText(find.byType(TextField), '41');
      await _settle(tester);
      await tester.tap(find.text('Start session'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '42');
      await _settle(tester);
      await tester.tap(find.text('Start session'));
      await _settle(tester);

      expect(repository.pinAttempts, ['41', '42']);
      expect(find.text('Handshake complete'), findsOneWidget);
    });
  });


  group('ending a live session', () {
    testWidgets('the confirmation is what sends it', (tester) async {
      final repository = FakeSessionsRepository(
        sessions: [session(status: 'in_progress')],
      );
      await _pumpDetail(tester, repository, _tutee);

      await tester.tap(find.text('End session'));
      await _settle(tester);

      // A completed session is terminal in the API's transition table, so the
      // button is the only moment at which the student sees what they are giving up.
      expect(find.text('End this session?'), findsOneWidget);
      expect(repository.endedSessionIds, isEmpty);

      await tester.tap(find.text('Keep going'));
      await _settle(tester);
      expect(repository.endedSessionIds, isEmpty);
    });

    testWidgets('confirming ends it and offers the rating', (tester) async {
      final repository = FakeSessionsRepository(
        sessions: [session(status: 'in_progress')],
      );
      await _pumpDetail(tester, repository, _tutee);

      await tester.tap(find.text('End session'));
      await _settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('End session'),
        ),
      );
      await _settle(tester);

      expect(repository.endedSessionIds, [_sessionId]);
      // The completed session must move through the rating form before the
      // quality loop is complete.
      expect(find.text('Rate this session'), findsOneWidget);
    });
  });

  group('rating', () {
    testWidgets('a completed session offers the rating screen', (tester) async {
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session(status: 'completed')]),
        _tutee,
      );

      expect(find.text('Rate this session'), findsOneWidget);
    });

    testWidgets('a session with no PIN and no action is not dressed up', (
      tester,
    ) async {
      // A no-show is the case where a rating might be tempting and must not be.
      await _pumpDetail(
        tester,
        FakeSessionsRepository(sessions: [session(status: 'no_show')]),
        _tutee,
      );

      expect(find.text('Rate this session'), findsNothing);
      expect(find.textContaining('did not take place'), findsOneWidget);
    });

    testWidgets('a session already rated by someone else says only that', (
      tester,
    ) async {
      // `is_rated` is true for both parties of a rated session, so telling a tutor
      // they have rated their own session would be a lie.
      await _pumpDetail(
        tester,
        FakeSessionsRepository(
          sessions: [session(status: 'completed', isRated: true)],
        ),
        _tutor,
      );

      expect(find.text('This session has been rated.'), findsOneWidget);
      expect(find.text('Rate this session'), findsNothing);
    });
  });
}
