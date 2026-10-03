import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/app/app.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/app/splash_screen.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';
import 'package:peerpass/features/auth/presentation/screens/sign_up_screen.dart';
import 'package:peerpass/features/incentives/data/repositories/fake_incentives_repository.dart';
import 'package:peerpass/features/incentives/data/repositories/incentives_repository.dart';
import 'package:peerpass/features/incentives/presentation/screens/certificate_screen.dart';
import 'package:peerpass/features/matching/data/repositories/fake_matching_repository.dart';
import 'package:peerpass/features/matching/data/repositories/matching_repository.dart';
import 'package:peerpass/features/matching/presentation/screens/tutor_requests_screen.dart';
import 'package:peerpass/features/sessions/data/repositories/fake_sessions_repository.dart';
import 'package:peerpass/features/sessions/data/repositories/sessions_repository.dart';

const String _signedOutText = 'Sign in';

/// The greeting home builds from the stored name. Asserting on this rather than
/// on a placeholder string means the test fails if the profile stopped reaching
/// the screen, which is the thing it is actually about.
const String _homeText = 'Hello, Achieng';

/// A student who has finished onboarding.
const UserProfile _enrolled = UserProfile(
  publicId: 'user-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: {UserRole.student},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
  primaryCourseUnitIds: ['unit-1'],
);

/// A student who has signed up but has not run the wizard.
const UserProfile _freshAccount = UserProfile(
  publicId: 'user-2',
  email: 'newcomer@must.ac.ug',
  roles: {UserRole.student},
);

/// The same account once they have been approved to teach.
const UserProfile _tutor = UserProfile(
  publicId: 'user-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: {UserRole.student, UserRole.tutor},
  universityId: 'university-1',
  facultyId: 'subject-1',
  yearOfStudy: 2,
  primaryCourseUnitIds: ['unit-1'],
);

/// A repository whose restore stays pending until the test releases it.
///
/// Needed to observe the window where the auth status is genuinely unknown. The
/// fake resolves within a microtask, so the app would pass straight through
/// splash and the redirect would never be seen mid-flight.
///
/// Extends the fake rather than implementing the contract, so it keeps answering
/// sign-in and profile calls if a test needs them.
class _GatedAuthRepository extends FakeAuthRepository {
  final Completer<UserProfile?> _gate = Completer<UserProfile?>();

  void release({UserProfile? profile}) => _gate.complete(profile);

  @override
  Future<UserProfile?> restoreSession() => _gate.future;
}

/// A repository that fails the cold-start check the way a dropped connection
/// does, rather than reporting signed out.
class _OfflineAuthRepository extends FakeAuthRepository {
  @override
  Future<UserProfile?> restoreSession() async {
    throw const NetworkFailure();
  }
}

FakeAuthRepository _signedIn({UserProfile? profile}) {
  return FakeAuthRepository(
    session: profile ?? _enrolled,
    refreshToken: 'refresh',
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('lands on sign-in when there is no stored session', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    expect(find.text(_signedOutText), findsOneWidget);
  });

  testWidgets('lands on home when a stored session restores', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_signedIn()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    expect(find.text(_homeText), findsOneWidget);
  });

  testWidgets('holds on splash while the session is still unknown', (
    tester,
  ) async {
    final repository = _GatedAuthRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(repository)],
        child: const PeerPassApp(),
      ),
    );
    await tester.pump();

    // The restore has not returned, so the app must still be on splash rather
    // than flashing sign-in at a returning user.
    expect(find.byType(SplashScreen), findsOneWidget);

    repository.release();
    await _settle(tester);

    expect(find.byType(SplashScreen), findsNothing);
    expect(find.text(_signedOutText), findsOneWidget);
  });

  testWidgets('a new account is sent to onboarding rather than home', (
    tester,
  ) async {
    // The whole point of onboarding existing: signing up gets you a session, and
    // a session alone is not a usable account. Landing such a student on home
    // would show them a shell with nothing in it and no route to filling it in.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            _signedIn(profile: _freshAccount),
          ),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    expect(find.text(_homeText), findsNothing);
    expect(find.text('What is your name?'), findsOneWidget);
  });

  testWidgets('a network failure keeps the user on splash with a way out', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_OfflineAuthRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    // Not signed in, and not stranded: the splash screen says what happened and
    // offers a retry, because a student on a train is not signed out.
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('an auth change redirects without the screen asking', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(_signedIn()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);
    expect(find.text(_homeText), findsOneWidget);

    await container.read(authControllerProvider).signOut();
    await _settle(tester);

    expect(find.text(_signedOutText), findsOneWidget);
    expect(find.text(_homeText), findsNothing);
  });

  testWidgets('a deep link to home is sent to sign-in when signed out', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).go(AppRoutes.home);
    await _settle(tester);

    expect(find.text(_signedOutText), findsOneWidget);
  });

  testWidgets('the sign-in screen can reach the sign-up screen', (tester) async {
    // Regression. The redirect guard exempted only /sign-in while signed out, so
    // tapping "Create one" navigated to /sign-up and was immediately redirected
    // back. The button therefore did nothing at all.
    //
    // This test taps the button and goes through the real router, which is the
    // only arrangement that could have caught it. `sign_up_screen_test.dart`
    // pumps `SignUpScreen` directly, so it proved the screen renders and said
    // nothing about whether anything could ever navigate to it.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);
    expect(find.text(_signedOutText), findsOneWidget);

    await tester.tap(find.text('No account yet? Create one'));
    await _settle(tester);

    expect(find.byType(SignUpScreen), findsOneWidget);
    expect(
      find.text(_signedOutText),
      findsNothing,
      reason: 'the guard bounced the student back to sign-in',
    );
    expect(
      Router.of(
        tester.element(find.byType(SignUpScreen)),
      ).routeInformationProvider!.value.uri.path,
      AppRoutes.signUp,
    );
  });

  testWidgets('a deep link to sign-up is allowed while signed out', (
    tester,
  ) async {
    // The same rule from the other direction: a shared /sign-up link must open
    // the sign-up screen rather than bounce to sign-in.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).go(AppRoutes.signUp);
    await _settle(tester);

    expect(find.byType(SignUpScreen), findsOneWidget);
  });

  testWidgets('a deep link to onboarding is sent to sign-in when signed out', (
    tester,
  ) async {
    // The guard is widened, so the routes it must still refuse are pinned here.
    // Without this, "widen the allow-list" and "let anyone in" look identical.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).go(AppRoutes.onboarding);
    await _settle(tester);

    expect(find.text(_signedOutText), findsOneWidget);
    expect(find.byType(SignUpScreen), findsNothing);
  });

  testWidgets('the certificate screen is reached from home and kept by the guard', (
    tester,
  ) async {
    // The whole chain for one route: the entry on home, the registration in the
    // shell's router, and the redirect guard declining to send the tutor back to
    // the dashboard. A test of the screen alone would pass against a route that
    // was never registered, and a test of the route alone would pass against a
    // screen that hangs on splash.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_signedIn(profile: _tutor)),
          incentivesRepositoryProvider.overrideWithValue(
            FakeIncentivesRepository(certifiedMinutes: 600),
          ),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    expect(find.text(_homeText), findsOneWidget);

    // Scrolled to rather than tapped where it happens to be. The dashboard is a
    // scroll view and the tutor-only entries sit below the fold once the rail is
    // on screen, so a tap at the recorded position would land on whatever happens
    // to be there instead of the entry -- which reads as a broken tile rather than
    // as a test that did not scroll.
    await tester.scrollUntilVisible(find.text('My certificate'), 200);
    await _settle(tester);

    await tester.tap(find.text('My certificate'));
    await _settle(tester);

    expect(find.byType(CertificateScreen), findsOneWidget);
    expect(find.text('10h of 40h'), findsOneWidget);
    expect(find.text(_homeText), findsNothing);
  });

  testWidgets('the waiting list is reached from home and kept by the guard', (
    tester,
  ) async {
    // The other half of the choice, and the same chain as the certificate: the
    // entry on home, the registration in the shell's router, and the guard
    // declining to send the tutor back. Without the route registration this screen
    // would exist, be tested in isolation, and be unreachable in the app.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_signedIn(profile: _tutor)),
          matchingRepositoryProvider.overrideWithValue(FakeMatchingRepository()),
          sessionsRepositoryProvider.overrideWithValue(FakeSessionsRepository()),
        ],
        child: const PeerPassApp(),
      ),
    );
    await _settle(tester);

    await tester.scrollUntilVisible(find.text('Waiting on you'), 200);
    await _settle(tester);

    await tester.tap(find.text('Waiting on you'));
    await _settle(tester);

    expect(find.byType(TutorRequestsScreen), findsOneWidget);
    // The empty state, because this fake proposes nobody. What is asserted is the
    // screen and its honest copy, not the absence of an error.
    expect(find.text('No one is waiting on you'), findsOneWidget);
    expect(find.text(_homeText), findsNothing);
  });
}
