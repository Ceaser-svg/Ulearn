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
import 'package:peerpass/features/sessions/presentation/widgets/active_session_card.dart';

const UserProfile _tutee = UserProfile(
  publicId: 'student-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
);

SessionModel session({
  required String id,
  String topic = 'Second order ODEs',
  String status = 'scheduled',
}) {
  return SessionModel.fromJson({
    'id': id,
    'tutee_id': _tutee.publicId,
    'tutor_id': 'tutor-1',
    'course_unit_id': 'unit-1',
    'course_unit_code': 'MAT 221',
    'course_unit_name': 'Linear Algebra',
    'tutee_name': 'Adongo Sarah',
    'tutor_name': 'Okello Daniel',
    'topic': topic,
    'status': status,
    'duration_minutes': 60,
    'is_rated': false,
    'created_at': '2026-03-01T08:00:00Z',
    'scheduled_start': '2026-03-04T09:00:00Z',
    'session_pin': '42',
  });
}

ProviderContainer _container(SessionsRepository repository) {
  final container = ProviderContainer(
    overrides: [
      sessionsRepositoryProvider.overrideWithValue(repository),
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(session: _tutee, refreshToken: 'refresh'),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(_tutee);
  return container;
}

/// Pumps the card on its own, which is how the router hands it to home.
Future<void> _pumpCard(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: ActiveSessionCard()),
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

class _OfflineSessionsRepository extends FakeSessionsRepository {
  @override
  Future<List<SessionModel>> sessionsForMe() async {
    throw const NetworkFailure();
  }
}

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
  testWidgets('shows nothing at all when there is nothing to act on', (
    tester,
  ) async {
    await _pumpCard(tester, _container(FakeSessionsRepository()));

    // A card-shaped hole in the dashboard would be worse than no card. Home is not
    // a loading state and the rest of it is already true.
    expect(find.byType(Card), findsNothing);
    expect(find.byType(ActiveSessionCard), findsOneWidget);
  });

  testWidgets('a live session is shown ahead of a waiting one', (tester) async {
    // The API's order decides between equals; a live session outranks a scheduled
    // one because it is the one with a handshake waiting to happen.
    await _pumpCard(
      tester,
      _container(
        FakeSessionsRepository(
          sessions: [
            session(id: 'next-1', topic: 'Upcoming'),
            session(id: 'live-1', topic: 'Happening now', status: 'in_progress'),
          ],
        ),
      ),
    );

    expect(find.text('Happening now'), findsOneWidget);
    expect(find.text('Upcoming'), findsNothing);
    expect(find.text('In progress'), findsOneWidget);
  });

  testWidgets('a session that is over is not on the dashboard', (tester) async {
    // Home shows what is ahead of the user. The history is one tap away on the list
    // screen, and a dashboard that lists everything is a list with a greeting above
    // it.
    await _pumpCard(
      tester,
      _container(
        FakeSessionsRepository(
          sessions: [session(id: 'done-1', topic: 'Finished', status: 'completed')],
        ),
      ),
    );

    expect(find.text('Finished'), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('a failed fetch is said once, quietly, and can be retried', (
    tester,
  ) async {
    // Swallowed silently it would read as "you have no sessions", which is a
    // different claim from "we could not ask".
    await _pumpCard(tester, _container(_OfflineSessionsRepository()));

    expect(find.text("Couldn't load your sessions."), findsOneWidget);
    expect(find.byTooltip('Retry sessions'), findsOneWidget);
  });

  testWidgets('retrying reaches for the sessions again', (tester) async {
    await _pumpCard(
      tester,
      _container(_FlakySessionsRepository([session(id: 'next-1')])),
    );
    expect(find.text("Couldn't load your sessions."), findsOneWidget);

    await tester.tap(find.byTooltip('Retry sessions'));
    await _settle(tester);

    expect(find.text('Second order ODEs'), findsOneWidget);
  });

  testWidgets('an unregistered repository does not put an exception on screen', (
    tester,
  ) async {
    // The real app has to register the sessions repository in `main.dart`, which is
    // the composition root's job and not this widget's. Until that is done, every
    // test that mounts home through the real router reads the *unoverridden*
    // provider, whose whole message is
    // `UnimplementedError: sessionsRepositoryProvider must be overridden in
    // ProviderScope.`
    //
    // If that reached the card it would put a Dart error on a student's dashboard
    // and take down every app-shell test. The card has to survive a repository that
    // was never registered, because "the provider threw UnimplementedError" is a
    // state the app is genuinely in.
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(session: _tutee, refreshToken: 'refresh'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(sessionControllerProvider.notifier).signedIn(_tutee);

    await _pumpCard(tester, container);

    expect(
      find.textContaining('UnimplementedError'),
      findsNothing,
      reason: 'a missing override must not reach a screen',
    );
    expect(find.textContaining('must be overridden'), findsNothing);
    // It says it could not load, which is the truth, rather than pretending the
    // user has no sessions.
    expect(find.text("Couldn't load your sessions."), findsOneWidget);
  });
}
