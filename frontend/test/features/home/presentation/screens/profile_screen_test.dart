import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
);

Future<ProviderContainer> _pumpProfile(
  WidgetTester tester,
  AuthRepository repository,
) async {
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  container.read(sessionControllerProvider.notifier).signedIn(_profile);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light, home: const ProfileScreen()),
    ),
  );
  await tester.pump();
  return container;
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
}

class _UnavailableUniversityRepository extends FakeAuthRepository {
  @override
  Future<List<UniversityOption>> universities() async {
    throw StateError('catalogue unavailable');
  }
}
