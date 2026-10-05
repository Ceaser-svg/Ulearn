import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit_option.dart';
import 'package:peerpass/core/models/grade_option.dart';
import 'package:peerpass/core/models/university_option.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/theme/app_theme.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/competencies/data/repositories/fake_competencies_repository.dart';
import 'package:peerpass/features/competencies/presentation/providers/competency_providers.dart';
import 'package:peerpass/features/competencies/presentation/screens/submit_claim_screen.dart';

const UserProfile _student = UserProfile(
  publicId: 'user-1',
  email: 'student@must.ac.ug',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
  facultyId: 'faculty-1',
  fullName: 'Amina Nansubuga',
);

const List<CourseUnitOption> _courseUnits = <CourseUnitOption>[
  CourseUnitOption(
    publicId: 'unit-1',
    code: 'BIT 221',
    name: 'Database Programming',
  ),
  CourseUnitOption(
    publicId: 'unit-2',
    code: 'BIT 311',
    name: 'Software Engineering',
  ),
];

const List<GradeOption> _gradeOptions = <GradeOption>[
  GradeOption(publicId: 'grade-1', label: 'B+', gradePoints: 4.5),
  // The grade scale stores exact decimal values, including the A benchmark.
  // ignore: prefer_int_literals
  GradeOption(publicId: 'grade-2', label: 'A', gradePoints: 5.0),
];

Future<void> _pumpScreen(
  WidgetTester tester,
  FakeAuthRepository repo, {
  FakeCompetenciesRepository? claims,
}) async {
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(repo),
      competenciesRepositoryProvider.overrideWithValue(
        claims ?? FakeCompetenciesRepository(),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(_student);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const SubmitClaimScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows the MUST grade options when the live grade catalogue is empty',
    (tester) async {
      final repository = FakeAuthRepository(
        session: _student,
        refreshToken: 'refresh',
        universityOptions: const [
          UniversityOption(
            publicId: 'university-1',
            name: 'Mbarara University of Science and Technology',
          ),
        ],
        courseUnitOptions: _courseUnits,
      );

      await _pumpScreen(tester, repository);

      await tester.tap(find.byKey(const ValueKey('Grade')));
      await tester.pumpAndSettle();

      expect(find.text('B+ (4.5)').last, findsOneWidget);
      expect(
        find.text(
          'Showing the saved MUST grading scale while we refresh the catalogue.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a student can submit tutor proof for one unit', (tester) async {
    final repository = FakeAuthRepository(
      session: _student,
      refreshToken: 'refresh',
      courseUnitOptions: _courseUnits,
      gradeOptions: _gradeOptions,
    );
    final claims = FakeCompetenciesRepository();

    await _pumpScreen(tester, repository, claims: claims);

    await tester.tap(find.byKey(const ValueKey('Course unit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BIT 221 · Database Programming').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('Grade')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B+ (4.5)').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Evidence reference or link'),
      'https://drive.example/transcript.pdf',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Notes for the reviewer'),
      'I completed this in my final year.',
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Submit proof'));
    await tester.tap(find.text('Submit proof'));
    await tester.pumpAndSettle();

    expect(claims.submitted, hasLength(1));
    expect(claims.submitted.single.source, 'transcript');
    expect(claims.submitted.single.courseUnitId, 'unit-1');
    expect(claims.submitted.single.gradeId, 'grade-1');
    // The evidence and notes reach the API. Losing them here would leave a tutor
    // who did the work unable to show it.
    expect(
      claims.submitted.single.evidenceReference,
      'https://drive.example/transcript.pdf',
    );
    expect(claims.submitted.single.notes, 'I completed this in my final year.');
  });

  testWidgets('requires an explicit grade selection', (tester) async {
    final repository = FakeAuthRepository(
      session: _student,
      refreshToken: 'refresh',
      courseUnitOptions: _courseUnits,
      gradeOptions: _gradeOptions,
    );

    final claims = FakeCompetenciesRepository();
    await _pumpScreen(tester, repository, claims: claims);

    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Submit proof'),
    );
    expect(submit.onPressed, isNull);
    expect(claims.submitted, isEmpty);

    await tester.tap(find.byKey(const ValueKey('Grade')));
    await tester.pumpAndSettle();
    expect(find.text('Select grade').last, findsOneWidget);
  });

  testWidgets('a refused submission keeps the tutor on the form', (
    tester,
  ) async {
    // The API refuses a second claim for a unit. The message it sends is the only
    // thing that tells the tutor what happened, so it has to reach them, and their
    // answers have to survive: retyping an evidence reference to learn that it was
    // a duplicate would be the app's fault, not theirs.
    final repository = FakeAuthRepository(
      session: _student,
      refreshToken: 'refresh',
      courseUnitOptions: _courseUnits,
      gradeOptions: _gradeOptions,
    );
    final claims = FakeCompetenciesRepository()
      ..submitError = const ConflictFailure(
        'A competency already exists for this unit.',
      );

    await _pumpScreen(tester, repository, claims: claims);

    await tester.tap(find.byKey(const ValueKey('Grade')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B+ (4.5)').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Evidence reference or link'),
      'transcript ref 4471',
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Submit proof'));
    await tester.tap(find.text('Submit proof'));
    await tester.pumpAndSettle();

    expect(
      find.text('A competency already exists for this unit.'),
      findsOneWidget,
    );
    // Still on the form, still holding what was typed.
    expect(find.text('Submit proof'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Evidence reference or link'),
      findsOneWidget,
    );
    expect(find.text('Awaiting review'), findsNothing);
  });

  testWidgets('a submitted claim is recorded and made readable', (
    tester,
  ) async {
    // The link between the two screens. Without the refresh the applications
    // screen would report "you have not applied yet" to a tutor who had just
    // submitted proof, which is the one thing it must never say.
    final repository = FakeAuthRepository(
      session: _student,
      refreshToken: 'refresh',
      courseUnitOptions: _courseUnits,
      gradeOptions: _gradeOptions,
    );
    final claims = FakeCompetenciesRepository();

    await _pumpScreen(tester, repository, claims: claims);

    await tester.tap(find.byKey(const ValueKey('Grade')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B+ (4.5)').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Submit proof'));
    await tester.tap(find.text('Submit proof'));
    await tester.pumpAndSettle();

    // The controller invalidated the list provider, so a read must now produce
    // the claim the fake holds rather than the empty list it started with.
    final stored = await claims.myClaims();
    expect(stored, hasLength(1));
    expect(stored.single.isPending, isTrue);
    expect(stored.single.statusLabel, 'Awaiting review');
  });
}
