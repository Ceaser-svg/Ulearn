import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/theme/app_theme.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';
import 'package:peerpass/features/competencies/data/repositories/competencies_repository.dart';
import 'package:peerpass/features/competencies/data/repositories/fake_competencies_repository.dart';
import 'package:peerpass/features/competencies/presentation/providers/competency_providers.dart';
import 'package:peerpass/features/competencies/presentation/screens/my_applications_screen.dart';

TutorClaim claim({
  String id = 'claim-1',
  String status = 'pending',
  String? rejectionReason,
  bool hasRejectionReason = true,
  String courseUnitCode = 'MAT 221',
  String courseUnitName = 'Linear Algebra',
  String gradeLabel = 'A',
}) {
  return TutorClaim(
    id: id,
    courseUnitId: 'unit-$id',
    courseUnitCode: courseUnitCode,
    courseUnitName: courseUnitName,
    gradeId: 'grade-$id',
    gradeLabel: gradeLabel,
    statusWire: status,
    status: TutorClaimStatus.fromWire(status),
    gradePoints: 5,
    meetsThreshold: status == 'verified',
    createdAt: DateTime.utc(2026, 3, 1, 8),
    verifiedAt: status == 'verified' ? DateTime.utc(2026, 3, 2, 9) : null,
    rejectionReason: hasRejectionReason ? rejectionReason : null,
    evidenceReference: 'Semester 5 transcript',
  );
}

/// A container with [repository] behind the competencies provider.
///
/// Only that one provider is overridden. The screen reads nothing about the
/// signed-in account -- `GET /v1/competencies/me` is self-scoped -- so a test
/// that had to stand up a session first would be testing something the screen
/// does not do.
ProviderContainer _container(CompetenciesRepository repository) {
  final container = ProviderContainer(
    overrides: [competenciesRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const MyApplicationsScreen()),
      for (final (path, label) in [
        ('/tutor-verification', 'submission form'),
        ('/tutor-applications', 'applications'),
      ])
        GoRoute(
          path: path,
          builder: (_, _) =>
              Scaffold(body: Text(label, textDirection: TextDirection.ltr)),
        ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

void main() {
  group('the applications screen', () {
    testWidgets('shows a pending claim as awaiting review', (tester) async {
      await _pump(
        tester,
        _container(FakeCompetenciesRepository(claims: [claim()])),
      );

      expect(find.text('Tutor applications'), findsOneWidget);
      expect(find.text('MAT 221 · Linear Algebra'), findsOneWidget);
      expect(find.text('Claimed A'), findsOneWidget);
      expect(find.text('Awaiting review'), findsOneWidget);
      // A claim nobody has decided yet carries no reason and offers no way to
      // resubmit, because the API would refuse it.
      expect(find.text('What to change'), findsNothing);
      expect(find.text('Submit different proof'), findsNothing);
    });

    testWidgets('shows a verified claim as verified', (tester) async {
      await _pump(
        tester,
        _container(
          FakeCompetenciesRepository(claims: [claim(status: 'verified')]),
        ),
      );

      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Awaiting review'), findsNothing);
    });

    testWidgets('a rejection shows the reason it was refused', (tester) async {
      // The reason this screen exists: a tutor whose proof was refused used to
      // have no way to learn why, because the submission response was discarded
      // and the endpoint carrying the reason was read by nothing.
      await _pump(
        tester,
        _container(
          FakeCompetenciesRepository(
            claims: [
              claim(
                status: 'rejected',
                rejectionReason:
                    'The transcript reference does not name the course.',
              ),
            ],
          ),
        ),
      );

      expect(find.text('Not accepted'), findsOneWidget);
      expect(find.text('What to change'), findsOneWidget);
      expect(
        find.text('The transcript reference does not name the course.'),
        findsOneWidget,
      );
      expect(find.text('Submit different proof'), findsOneWidget);
    });

    testWidgets('a rejection with no recorded reason says so plainly', (
      tester,
    ) async {
      // An empty space where the reason should be would read as the tutor having
      // done something wrong. Saying the reason is missing is what is true.
      await _pump(
        tester,
        _container(
          FakeCompetenciesRepository(
            claims: [claim(status: 'rejected', hasRejectionReason: false)],
          ),
        ),
      );

      expect(find.text('Not accepted'), findsOneWidget);
      expect(find.text('What to change'), findsNothing);
      expect(
        find.text(
          'No reason was recorded. Contact the operations team to ask why.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('each unit is listed, not just the latest', (tester) async {
      await _pump(
        tester,
        _container(
          FakeCompetenciesRepository(
            claims: [
              claim(id: 'a'),
              claim(
                id: 'b',
                courseUnitCode: 'PHY 211',
                courseUnitName: 'Mechanics',
                status: 'verified',
              ),
            ],
          ),
        ),
      );

      expect(find.text('MAT 221 · Linear Algebra'), findsOneWidget);
      expect(find.text('PHY 211 · Mechanics'), findsOneWidget);
      expect(find.text('Awaiting review'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
    });

    testWidgets('a tutor who has not applied is offered the form', (
      tester,
    ) async {
      await _pump(tester, _container(FakeCompetenciesRepository()));

      expect(find.text('You have not applied yet'), findsOneWidget);
      expect(find.text('Apply to teach'), findsOneWidget);

      await tester.tap(find.text('Apply to teach'));
      await tester.pumpAndSettle();

      expect(find.text('submission form'), findsOneWidget);
    });

    testWidgets('a lost connection is said once and can be retried', (
      tester,
    ) async {
      final repository = FakeCompetenciesRepository()
        ..listError = const NetworkFailure('No connection.');
      await _pump(tester, _container(repository));

      expect(find.text('No connection.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // Recovered, and now saying something true rather than the empty state
      // the screen would show for someone who has not applied.
      expect(find.text('You have not applied yet'), findsOneWidget);
    });

    testWidgets('a failure the client did not expect is not shown raw', (
      tester,
    ) async {
      // The repository turns every transport fault into a Failure, so an
      // `AsyncValue.error` reaching here untranslated means the client itself is
      // at fault. It must still say so in words rather than printing whatever
      // was thrown.
      await _pump(tester, _container(_ExplodingRepository()));

      expect(find.textContaining('StateError'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('the screen refreshes on demand', (tester) async {
      final repository = FakeCompetenciesRepository();
      final container = _container(repository);
      await _pump(tester, container);

      expect(find.text('You have not applied yet'), findsOneWidget);

      // A reviewer decides out of band; the tutor pulls to refresh and sees it.
      repository.claims.add(claim(status: 'verified'));
      await tester.fling(
        find.text('You have not applied yet'),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(find.text('MAT 221 · Linear Algebra'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
    });
  });
}

/// Throws something the repository contract does not allow.
class _ExplodingRepository implements CompetenciesRepository {
  @override
  Future<List<TutorClaim>> myClaims() async =>
      throw StateError('something the client did not expect');

  @override
  Future<TutorClaim> submitClaim({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  }) async => throw StateError('unreachable');
}
