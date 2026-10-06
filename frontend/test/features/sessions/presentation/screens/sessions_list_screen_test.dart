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
import 'package:peerpass/features/sessions/presentation/screens/sessions_list_screen.dart';

/// The signed-in student, so the role-based halves of the session UI have an
/// identity to compare against.
const UserProfile _student = UserProfile(
  publicId: 'student-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
);

/// The tutor from the other side of the same sessions.
const String _tutorId = 'tutor-1';

/// A session as the API would return it, with the fields a test does not care
/// about left at their neutral defaults.
SessionModel session({
  required String id,
  String topic = 'Second order ODEs',
  String status = 'scheduled',
  String? sessionPin = '42',
  bool isRated = false,
  int durationMinutes = 60,
  String? meetingLink,
}) {
  return SessionModel.fromJson({
    'id': id,
    'tutee_id': _student.publicId,
    'tutor_id': _tutorId,
    'course_unit_id': 'unit-1',
    'course_unit_code': 'MAT 221',
    'course_unit_name': 'Linear Algebra',
    'tutee_name': 'Adongo Sarah',
    'tutor_name': 'Okello Daniel',
    'topic': topic,
    'status': status,
    'duration_minutes': durationMinutes,
    'is_rated': isRated,
    'created_at': '2026-03-01T08:00:00Z',
    'scheduled_start': '2026-03-04T09:00:00Z',
    'session_pin': sessionPin,
    'meeting_link': meetingLink,
  });
}

/// A container with [repository] behind the sessions provider, signed in.
ProviderContainer _container(SessionsRepository repository) {
  final container = ProviderContainer(
    overrides: [
      sessionsRepositoryProvider.overrideWithValue(repository),
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(session: _student, refreshToken: 'refresh'),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(_student);
  return container;
}

Future<void> _pumpList(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const SessionsListScreen(),
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

/// A repository that fails the way a dropped connection does.
class _OfflineSessionsRepository extends FakeSessionsRepository {
  @override
  Future<List<SessionModel>> sessionsForMe() async {
    throw const NetworkFailure();
  }
}

/// A repository whose first listing fails and whose second answers.
class _FlakySessionsRepository extends FakeSessionsRepository {
  _FlakySessionsRepository(this._recovered);

  final List<SessionModel> _recovered;
  int _attempts = 0;

  @override
  Future<List<SessionModel>> sessionsForMe() async {
    _attempts++;
    if (_attempts == 1) throw const NetworkFailure();
    return _recovered;
  }
}

void main() {
  testWidgets('says so plainly when there are no sessions at all', (
    tester,
  ) async {
    await _pumpList(tester, _container(FakeSessionsRepository()));

    // Not a spinner that never ends and not a blank list: the API answered, and
    // the answer was nothing.
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('No sessions yet'), findsOneWidget);
  });

  testWidgets('splits what is ahead of the user from what is behind', (
    tester,
  ) async {
    await _pumpList(
      tester,
      _container(
        FakeSessionsRepository(
          sessions: [
            session(id: 'live-1', topic: 'Live now', status: 'in_progress'),
            session(id: 'next-1', topic: 'Upcoming'),
            session(id: 'done-1', topic: 'Finished', status: 'completed'),
            session(id: 'gone-1', topic: 'Did not happen', status: 'cancelled'),
            session(id: 'missed-1', topic: 'Missed', status: 'no_show'),
          ],
        ),
      ),
    );

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Past'), findsOneWidget);
    expect(find.text('Live now'), findsOneWidget);
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Did not happen'), findsOneWidget);
    // A no-show is past, because it did not happen. Filing it as upcoming would
    // offer the student a session they are not going to.
    expect(find.text('Missed'), findsOneWidget);
  });

  testWidgets('an unrecognised state is shown verbatim and not offered', (
    tester,
  ) async {
    await _pumpList(
      tester,
      _container(
        FakeSessionsRepository(
          sessions: [session(id: 'odd-1', status: 'rescheduled')],
        ),
      ),
    );

    expect(find.text('rescheduled'), findsOneWidget);
    expect(find.text('Active'), findsNothing);
  });

  testWidgets('a failed fetch says what happened and offers another try', (
    tester,
  ) async {
    await _pumpList(tester, _container(_OfflineSessionsRepository()));

    // The failure's own message, never the exception: a `DioException` or a
    // `TypeError` on a student's screen is a bug report about the app, not about
    // their connection.
    expect(find.text(const NetworkFailure().message), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('retrying after a failure goes back to the API', (tester) async {
    await _pumpList(
      tester,
      _container(_FlakySessionsRepository([session(id: 'next-1')])),
    );
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await _settle(tester);

    expect(find.text('Second order ODEs'), findsOneWidget);
  });

  testWidgets('a session row is a way into the session', (tester) async {
    await _pumpList(
      tester,
      _container(
        FakeSessionsRepository(
          sessions: [
            session(id: 'live-1', topic: 'Live now', status: 'in_progress'),
            session(id: 'next-1', topic: 'Upcoming'),
          ],
        ),
      ),
    );

    // Both rows are tappable and carry a chevron, which is the affordance a list
    // row without one cannot make: nothing on screen says "this leads somewhere".
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
  });
}
