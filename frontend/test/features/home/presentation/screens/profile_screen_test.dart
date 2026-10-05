import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/theme/app_theme.dart';
import 'package:peerpass/features/auth/data/models/university_option.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/home/presentation/screens/profile_screen.dart';

const _profile = UserProfile(
  publicId: 'user-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: {UserRole.student},
  universityId: 'university-1',
  facultyId: 'faculty-computing',
);

const _computing = Subject(publicId: 'faculty-computing', name: 'Computing');
const _medicine = Subject(publicId: 'faculty-medicine', name: 'Medicine');

Future<ProviderContainer> _pumpProfile(
  WidgetTester tester,
  AuthRepository repository, {
  UserProfile? profile,
}) async {
  // Seed both. The container's controller is what the screen reads, and the
  // repository's own copy is what it merges an update into and returns -- a fake
  // with no session answers `updateProfile` with a null profile, which is a
  // harness gap rather than anything the screen could handle.
  final signedIn = profile ?? _profile;
  if (repository is FakeAuthRepository) repository.session = signedIn;
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(signedIn);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light, home: const ProfileScreen()),
    ),
  );
  await tester.pump();
  return container;
}

FakeAuthRepository _repositoryWithFaculties() {
  return FakeAuthRepository(
    universityOptions: const [
      UniversityOption(publicId: 'university-1', name: 'MUST'),
    ],
    facultyOptions: const [_computing, _medicine],
  );
}

void main() {
  testWidgets('shows the university name rather than its identifier', (
    tester,
  ) async {
    final repository = FakeAuthRepository(
      universityOptions: const [
        UniversityOption(publicId: 'university-1', name: 'MUST'),
      ],
    );

    await _pumpProfile(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('MUST'), findsOneWidget);
    expect(find.text('university-1'), findsNothing);
  });

  testWidgets('does not expose the identifier when the catalogue fails', (
    tester,
  ) async {
    final repository = _UnavailableUniversityRepository();

    await _pumpProfile(tester, repository);
    await tester.pumpAndSettle();

    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('university-1'), findsNothing);
  });

  testWidgets('shows the faculty name rather than its identifier', (
    tester,
  ) async {
    await _pumpProfile(tester, _repositoryWithFaculties());
    await tester.pumpAndSettle();

    expect(find.text('Computing'), findsOneWidget);
    expect(find.text('faculty-computing'), findsNothing);
  });

  testWidgets('changing faculty sends only the faculty', (tester) async {
    // Only the faculty. A step that sent the whole record would blank the
    // university chosen on an earlier screen, which is the reason the wizard
    // saves one field at a time.
    final repository = _repositoryWithFaculties();

    await _pumpProfile(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medicine').last);
    await tester.pumpAndSettle();

    expect(repository.profileUpdates, hasLength(1));
    expect(repository.profileUpdates.single, {
      'faculty_id': 'faculty-medicine',
    });
  });

  testWidgets('changing faculty updates the session it is read from', (
    tester,
  ) async {
    // The screen reads the faculty from the session, so a save that did not
    // write the returned record back would leave the old name on screen after a
    // change the server had accepted.
    final repository = _repositoryWithFaculties();
    final container = await _pumpProfile(tester, repository);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Computing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medicine').last);
    await tester.pumpAndSettle();

    expect(
      container.read(sessionControllerProvider).profile?.facultyId,
      'faculty-medicine',
    );
    expect(find.text('Medicine'), findsWidgets);
    expect(find.text('Computing'), findsNothing);
  });

  testWidgets('says that the course units will need choosing again', (
    tester,
  ) async {
    // Changing faculty drops the primary modules chosen under the old one, and
    // the onboarding gate then asks for new ones. Left unsaid, that reads as a
    // fault rather than as a consequence of the change just made.
    await _pumpProfile(tester, _repositoryWithFaculties());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Computing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medicine').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Faculty updated. Choose the course units for your new faculty.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('reports a rejected change instead of showing it as saved', (
    tester,
  ) async {
    // The screen must not claim a change the API refused, and must not sign the
    // student out over it either.
    final repository = _RefusingFacultyRepository();

    await _pumpProfile(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medicine').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('faculty'), findsWidgets);
    expect(find.text('Faculty updated. Choose the course units'), findsNothing);
    expect(find.text('Computing'), findsWidgets);
  });

  testWidgets('offers no faculty to pick before a university is chosen', (
    tester,
  ) async {
    // Faculties belong to a university. With none chosen the tile says what is
    // missing instead of opening a sheet that could only be empty.
    final repository = _repositoryWithFaculties();

    await _pumpProfile(
      tester,
      repository,
      profile: const UserProfile(
        publicId: 'user-1',
        email: 'student@must.ac.ug',
        fullName: 'Achieng Okello',
        roles: {UserRole.student},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose a university first'), findsOneWidget);
    expect(repository.profileUpdates, isEmpty);
  });
}

/// Refuses every faculty change with a problem document the API would send.
class _RefusingFacultyRepository extends FakeAuthRepository {
  _RefusingFacultyRepository()
    : super(
        universityOptions: const [
          UniversityOption(publicId: 'university-1', name: 'MUST'),
        ],
        facultyOptions: const [_computing, _medicine],
      );

  @override
  Future<UserProfile> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  }) {
    throw const ValidationFailure(
      'That faculty could not be found.',
      fieldErrors: {'faculty_id': 'could not be found'},
    );
  }
}

class _UnavailableUniversityRepository extends FakeAuthRepository {
  @override
  Future<List<UniversityOption>> universities() async {
    throw StateError('catalogue unavailable');
  }
}
