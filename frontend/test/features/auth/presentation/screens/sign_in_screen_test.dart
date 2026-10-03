import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/theme/app_theme.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/auth/presentation/screens/sign_in_screen.dart';

/// The account a successful sign-in adopts.
///
/// Complete on purpose: the screen does not branch on the profile, so the only
/// thing the tests here can check about the outcome is that the session adopted
/// it. A half-filled profile would make an incomplete wizard the thing under
/// test instead of the sign-in form.
const UserProfile _enrolled = UserProfile(
  publicId: 'user-1',
  email: 'student@must.ac.ug',
  fullName: 'Achieng Okello',
  roles: <UserRole>{UserRole.student},
  universityId: 'university-1',
);

const String _email = 'student@must.ac.ug';
const String _password = 'correct horse battery';

/// What the API says when the address is unknown *or* the password is wrong.
///
/// Deliberately the same sentence for both: a student who mistypes an address
/// should not be able to use the error to find out whether somebody holds an
/// account here. The client has to show it verbatim rather than inventing
/// something more specific.
const String _wrongCredential = 'Email or password is incorrect';

/// The fake with the attempts counted.
///
/// "The form refused to submit" is only a real claim if something counts the
/// attempts. Asserting on the session instead would pass just as well if the
/// call had been made and had failed, which is the failure being ruled out.
class _CountingAuthRepository extends FakeAuthRepository {
  _CountingAuthRepository()
    : super(session: _enrolled, refreshToken: 'refresh');

  int signInAttempts = 0;

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) {
    signInAttempts++;
    return super.signIn(email: email, password: password);
  }
}

/// A repository that holds the call open until the test releases it.
///
/// Needed to observe the window where a submission is genuinely in flight. The
/// fake resolves within a microtask, so the button would be re-enabled before the
/// test ever got to look at it.
class _GatedAuthRepository extends _CountingAuthRepository {
  final Completer<UserProfile> _pending = Completer<UserProfile>();

  void failWith(Object error) => _pending.completeError(error);

  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) {
    signInAttempts++;
    return _pending.future;
  }
}

/// A repository that refuses the credentials the way the API does.
class _WrongPasswordAuthRepository extends _CountingAuthRepository {
  @override
  Future<UserProfile> signIn({
    required String email,
    required String password,
  }) async {
    signInAttempts++;
    throw const AuthFailure(_wrongCredential);
  }
}

/// The email input, found by the label the student reads.
final Finder _emailField = find.widgetWithText(TextFormField, 'Email address');

/// The password input, found through the reveal toggle.
///
/// The reveal button is built by the password field and nothing else, so this
/// does not depend on the label the field happens to be given.
final Finder _revealButton = find.byType(IconButton);

final Finder _passwordField = find.ancestor(
  of: _revealButton,
  matching: find.byType(TextFormField),
);

/// Where the obscured flag actually lives.
///
/// `TextFormField` is a wrapper around `TextField` and does not carry the flag
/// itself, so the assertion has to reach the field inside it.
final Finder _passwordInput = find.descendant(
  of: _passwordField,
  matching: find.byType(TextField),
);

/// The submit button, found by type.
///
/// By type rather than by label because the label is replaced by a progress
/// indicator while a submission is in flight, and the disabled state is exactly
/// when this file needs to look at it. The screen has one filled button: the
/// failure view it can show below the form is rendered without a retry.
final Finder _submitButton = find.byType(FilledButton);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

/// Whether the password is currently drawn as dots.
bool _passwordIsObscured(WidgetTester tester) =>
    tester.widget<TextField>(_passwordInput).obscureText;

/// Pumps the screen over a container the test keeps a handle on.
///
/// The handle is what lets a test read the session afterwards; a bare
/// `ProviderScope` would put it out of reach. The sign-in link is left without a
/// router on purpose -- nothing here navigates, and a `GoRouter` would only add
/// the auth guard the screen is not responsible for.
Future<ProviderContainer> _pumpSignIn(
  WidgetTester tester,
  AuthRepository repository, {
  bool disableAnimations = true,
  bool settle = true,
}) async {
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: const SignInScreen(),
        ),
      ),
    ),
  );
  if (settle) await _settle(tester);
  return container;
}

/// Fills both fields with something the form will accept.
Future<void> _enterValidCredentials(WidgetTester tester) async {
  await tester.enterText(_emailField, _email);
  await tester.enterText(_passwordField, _password);
  await tester.pump();
}

void main() {
  testWidgets('renders the supplied looping login animation', (tester) async {
    await _pumpSignIn(
      tester,
      _CountingAuthRepository(),
      disableAnimations: false,
      settle: false,
    );
    await tester.pump();

    final animation = tester.widget<Lottie>(find.byType(Lottie));
    expect(animation.repeat, isTrue);
    expect(animation.animate, isTrue);
  });

  testWidgets('disables login animation when reduced motion is enabled', (
    tester,
  ) async {
    await _pumpSignIn(tester, _CountingAuthRepository());

    final animation = tester.widget<Lottie>(find.byType(Lottie));
    expect(animation.animate, isFalse);
  });

  testWidgets('an empty form is refused without calling the repository', (
    tester,
  ) async {
    final repository = _CountingAuthRepository();
    final container = await _pumpSignIn(tester, repository);

    await tester.tap(_submitButton);
    await _settle(tester);

    expect(find.text('Email address is required'), findsOneWidget);
    expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(
      repository.signInAttempts,
      isZero,
      reason: 'a blank form is the client refusing it, not a request failing',
    );
    expect(
      container.read(sessionControllerProvider).status,
      isNot(SessionStatus.authenticated),
    );
  });

  testWidgets('a malformed address is refused before the repository is called', (
    tester,
  ) async {
    final repository = _CountingAuthRepository();
    await _pumpSignIn(tester, repository);

    await tester.enterText(_emailField, 'not-an-email');
    await tester.enterText(_passwordField, _password);
    await tester.pump();
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(repository.signInAttempts, isZero);
  });

  testWidgets('valid credentials sign in once and adopt the account', (
    tester,
  ) async {
    final repository = _CountingAuthRepository();
    final container = await _pumpSignIn(tester, repository);

    await _enterValidCredentials(tester);
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(repository.signInAttempts, 1);
    final session = container.read(sessionControllerProvider);
    expect(session.status, SessionStatus.authenticated);
    expect(session.profile, _enrolled);
    // The label is back in place of the spinner, so the form is at rest again.
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the reveal toggle flips the password between hidden and shown', (
    tester,
  ) async {
    await _pumpSignIn(tester, _CountingAuthRepository());
    await _enterValidCredentials(tester);

    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(
      _passwordIsObscured(tester),
      isTrue,
      reason: 'a shoulder-surfed password is still a leaked password',
    );

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    expect(_passwordIsObscured(tester), isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.byTooltip('Show password'), findsNothing);

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();

    expect(_passwordIsObscured(tester), isTrue);
  });

  testWidgets('a rejected password is shown rather than swallowed', (
    tester,
  ) async {
    // The one case worth a test on its own: the message is the only thing the
    // student has to go on, and a screen that caught the failure and rendered
    // nothing would look exactly like a slow connection.
    final repository = _WrongPasswordAuthRepository();
    await _pumpSignIn(tester, repository);

    await _enterValidCredentials(tester);
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(repository.signInAttempts, 1);
    expect(find.text(_wrongCredential), findsOneWidget);
    // No trace of the failure type or the transport behind it.
    expect(find.textContaining('AuthFailure'), findsNothing);
  });

  testWidgets('the button is disabled while a sign-in is in flight', (
    tester,
  ) async {
    final repository = _GatedAuthRepository();
    await _pumpSignIn(tester, repository);
    await _enterValidCredentials(tester);

    await tester.tap(_submitButton);
    // A single frame, deliberately: the button shows a progress indicator while
    // submitting, and settling would wait forever on it.
    await tester.pump();

    expect(tester.widget<FilledButton>(_submitButton).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(_submitButton);
    await tester.pump();
    expect(
      repository.signInAttempts,
      1,
      reason: 'a disabled button must not start a second request',
    );

    repository.failWith(const AuthFailure(_wrongCredential));
    await _settle(tester);

    expect(
      tester.widget<FilledButton>(_submitButton).onPressed,
      isNotNull,
      reason: 'a failed attempt has to be retryable',
    );
    expect(find.text(_wrongCredential), findsOneWidget);
  });
}
