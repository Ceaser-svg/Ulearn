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
import 'package:peerpass/features/auth/presentation/screens/sign_up_screen.dart';

const String _email = 'newcomer@must.ac.ug';
const String _password = 'correct horse battery';

/// Long enough to satisfy the rule, and deliberately not a real-looking secret.
const String _otherPassword = 'battery staple horse';

/// What the API says when the address is already in use.
const String _emailTaken = 'That email address is already registered';

/// The fake with the attempts counted, so a refused form can be shown to have
/// sent nothing rather than merely to have failed.
class _CountingAuthRepository extends FakeAuthRepository {
  int registerAttempts = 0;

  @override
  Future<UserProfile> register({
    required String email,
    required String password,
  }) {
    registerAttempts++;
    return super.register(email: email, password: password);
  }
}

/// A repository that refuses the address the way the API does.
///
/// Carries per-field detail as well as a summary, because that is the shape a
/// rejection arrives in: the summary is what the screen can show, and the
/// per-field map is the part that names the input at fault.
class _EmailTakenAuthRepository extends _CountingAuthRepository {
  @override
  Future<UserProfile> register({
    required String email,
    required String password,
  }) async {
    registerAttempts++;
    throw const ValidationFailure(
      _emailTaken,
      fieldErrors: <String, String>{'email': _emailTaken},
    );
  }
}

final Finder _emailField = find.widgetWithText(TextFormField, 'Email address');

final Finder _passwordField = find.ancestor(
  of: find.byType(IconButton),
  matching: find.byType(TextFormField),
);

final Finder _confirmationField = find.widgetWithText(
  TextFormField,
  'Confirm password',
);

/// The only filled button on the screen.
///
/// Found by type so it can be tapped while its label is replaced by a spinner,
/// and because the failure view below the form is rendered without a retry.
final Finder _submitButton = find.byType(FilledButton);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

/// Pumps the screen over a container the test keeps a handle on.
///
/// The screen's own link to sign-in is left without a router on purpose --
/// nothing here navigates, and a router would only add the auth guard that
/// `app_shell_test.dart` already covers.
Future<ProviderContainer> _pumpSignUp(
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
          child: const SignUpScreen(),
        ),
      ),
    ),
  );
  if (settle) await _settle(tester);
  return container;
}

/// Fills the form with something the shape checks accept.
Future<void> _enterValidForm(WidgetTester tester) async {
  await tester.enterText(_emailField, _email);
  await tester.enterText(_passwordField, _password);
  await tester.enterText(_confirmationField, _password);
  await tester.pump();
}

void main() {
  testWidgets('renders the supplied looping sign-up animation', (tester) async {
    await _pumpSignUp(
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

  testWidgets('disables sign-up animation when reduced motion is enabled', (
    tester,
  ) async {
    await _pumpSignUp(tester, _CountingAuthRepository());

    final animation = tester.widget<Lottie>(find.byType(Lottie));
    expect(animation.animate, isFalse);
  });

  testWidgets('a password shorter than the API requires is refused', (
    tester,
  ) async {
    // Twelve characters is the API's rule, and the form duplicates it so the
    // student is not billed a round trip to be told what they already know.
    final repository = _CountingAuthRepository();
    await _pumpSignUp(tester, repository);

    await tester.enterText(_emailField, _email);
    await tester.enterText(_passwordField, 'short');
    await tester.enterText(_confirmationField, 'short');
    await tester.pump();
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(
      repository.registerAttempts,
      isZero,
      reason: 'the client refuses it, so nothing is sent',
    );
  });

  testWidgets('a password of nothing but spaces is refused', (tester) async {
    // The length rule is measured after trimming, so a run of spaces long enough
    // to satisfy a naive character count is still refused. A password that
    // counts but stores nothing is a password the student believes they chose.
    final repository = _CountingAuthRepository();
    await _pumpSignUp(tester, repository);

    const spaces = '                ';
    await tester.enterText(_emailField, _email);
    await tester.enterText(_passwordField, spaces);
    await tester.enterText(_confirmationField, spaces);
    await tester.pump();
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    expect(repository.registerAttempts, isZero);
  });

  testWidgets('a confirmation that does not match is refused', (tester) async {
    final repository = _CountingAuthRepository();
    await _pumpSignUp(tester, repository);

    await tester.enterText(_emailField, _email);
    await tester.enterText(_passwordField, _password);
    await tester.enterText(_confirmationField, _otherPassword);
    await tester.pump();
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(find.text('Passwords do not match'), findsOneWidget);
    // The password itself was fine, so it must not be the one reported.
    expect(find.text('Password must be at least 8 characters'), findsNothing);
    expect(repository.registerAttempts, isZero);
  });

  testWidgets('a valid form registers a nameless student and signs them in', (
    tester,
  ) async {
    final repository = _CountingAuthRepository();
    final container = await _pumpSignUp(tester, repository);

    await _enterValidForm(tester);
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(repository.registerAttempts, 1);
    final session = container.read(sessionControllerProvider);
    expect(session.status, SessionStatus.authenticated);

    // Registration collects an address and a password and nothing else, so the
    // account comes back with no name. The wizard is what fills it in, and
    // `needsOnboarding` is the flag the router reads to send the student there.
    final profile = session.profile!;
    expect(profile.fullName, isNull);
    expect(profile.roles, <UserRole>{UserRole.student});
    expect(profile.needsOnboarding, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a rejected registration is shown to the student', (
    tester,
  ) async {
    // A silent refusal here is indistinguishable from a slow connection, and the
    // student has no way to tell which field the API was unhappy about.
    final repository = _EmailTakenAuthRepository();
    final container = await _pumpSignUp(tester, repository);

    await _enterValidForm(tester);
    await tester.tap(_submitButton);
    await _settle(tester);

    expect(repository.registerAttempts, 1);
    expect(find.text(_emailTaken), findsOneWidget);
    expect(
      container.read(sessionControllerProvider).status,
      isNot(SessionStatus.authenticated),
    );
    // Retryable rather than stranded: the button is live again.
    expect(tester.widget<FilledButton>(_submitButton).onPressed, isNotNull);
  });
}
