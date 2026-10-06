import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/app/splash_screen.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';
import 'package:peerpass/features/auth/presentation/screens/onboarding_screen.dart';
import 'package:peerpass/features/auth/presentation/screens/sign_in_screen.dart';
import 'package:peerpass/features/auth/presentation/screens/sign_up_screen.dart';
import 'package:peerpass/features/competencies/presentation/screens/my_applications_screen.dart';
import 'package:peerpass/features/competencies/presentation/screens/submit_claim_screen.dart';
import 'package:peerpass/features/home/presentation/screens/home_screen.dart';
import 'package:peerpass/features/home/presentation/screens/profile_screen.dart';
import 'package:peerpass/features/home/presentation/widgets/authenticated_shell.dart';
import 'package:peerpass/features/incentives/presentation/screens/certificate_screen.dart';
import 'package:peerpass/features/matching/presentation/screens/course_unit_picker_screen.dart';
import 'package:peerpass/features/matching/presentation/screens/match_results_screen.dart';
import 'package:peerpass/features/matching/presentation/screens/tutor_requests_screen.dart';
import 'package:peerpass/features/sessions/presentation/providers/session_providers.dart';
import 'package:peerpass/features/sessions/presentation/screens/confirm_request_screen.dart';
import 'package:peerpass/features/sessions/presentation/screens/rate_session_screen.dart';
import 'package:peerpass/features/sessions/presentation/screens/session_detail_screen.dart';
import 'package:peerpass/features/sessions/presentation/screens/sessions_tab_screen.dart';
import 'package:peerpass/features/sessions/presentation/widgets/active_session_card.dart';
import 'package:peerpass/features/tutors/presentation/providers/tutor_providers.dart';
import 'package:peerpass/features/tutors/presentation/screens/tutor_detail_screen.dart';
import 'package:peerpass/features/tutors/presentation/widgets/tutor_rail.dart';

/// Every location the shell can be at.
abstract final class AppRoutes {
  static const String splash = '/';
  static const String signIn = '/sign-in';
  static const String signUp = '/sign-up';
  static const String onboarding = '/onboarding';
  static const String tutorVerification = '/tutor-verification';
  static const String myApplications = '/tutor-applications';
  static const String home = '/home';
  static const String sessions = '/sessions';
  static const String profile = '/profile';
  static const String tutors = '/tutors';
  static const String matching = '/matching';
  static const String certificate = '/certificate';
  static const String tutorRequests = '/tutor-requests';

  /// One tutor's profile, opened from the rail.
  ///
  /// A path rather than a query, so the link to a tutor is something a student
  /// can put in a message to a classmate and have it open the same profile.
  static String tutorDetailPath(String userId) => '$tutors/$userId';

  /// The tutors the API will propose for one course unit.
  ///
  /// The unit is in the path for the same reason the session id is: the screen
  /// that answers "who can help with this course" is not reachable without the
  /// course, and a route that could not name it would be a link to nothing.
  static String matchResultsPath(String courseUnitId) =>
      '$matching/$courseUnitId';

  /// The list, a session, and that session's rating form.
  ///
  /// Written as helpers rather than string-concatenated at the call site, because
  /// the rating form is a *sibling* of the session it is about and both are
  /// children of the list. A path built by hand at the call site is one missing
  /// segment away from a route that exists and a screen that does not.
  static String sessionDetailPath(String sessionId) => '$sessions/$sessionId';

  static String rateSessionPath(String sessionId) =>
      '$sessions/$sessionId/rate';

  /// Confirming a help request the student named this tutor on.
  ///
  /// A query rather than a path segment, and the reason is what the path would
  /// have to carry: the student's question is free text, and a question is not
  /// something to paste unescaped into a route someone can share or a link can
  /// be truncated. [Uri] does the encoding, so a topic with a slash, an ampersand
  /// or a question mark of its own arrives as itself.
  ///
  /// These are the request's own values passed back in. The alternative -- the
  /// sessions feature fetching the request to recover them -- would make it own
  /// the matching feature's endpoint and put the tutor's decision behind a
  /// request that can fail for reasons unrelated to it.
  static String confirmRequestPath({
    required String requestId,
    required String courseUnitId,
    required String topic,
  }) => Uri(
    path: '$sessions/confirm',
    queryParameters: <String, String>{
      'request': requestId,
      'unit': courseUnitId,
      'topic': topic,
    },
  ).toString();
}

/// The session id out of a matched route, or the honest answer that there isn't one.
///
/// `/sessions` with a trailing slash matches the detail route with an empty
/// parameter. That is a link a person can type and a client can be handed, and
/// indexing an absent id would take the app down over a URL.
String? _sessionIdOf(GoRouterState state) => _idOf(state, 'sessionId');

/// A path parameter that is missing or empty.
///
/// One helper for every route with an id in its path. Three separate copies of
/// the same null-and-empty check is how one of them ends up accepting the empty
/// string that the other two reject.
String? _idOf(GoRouterState state, String parameter) {
  final id = state.pathParameters[parameter];
  if (id == null || id.isEmpty) return null;
  return id;
}

/// What a confirmation link carries, or the honest answer that it does not.
typedef _ConfirmRequest = ({
  String requestId,
  String courseUnitId,
  String topic,
});

/// A confirmation link missing any of the three things it is made of.
///
/// All three or nothing. A form with a request and no unit, or a topic and no
/// request, is a screen that renders and then fails on submit, which reads to the
/// tutor as the app refusing them rather than as a link that was never complete.
_ConfirmRequest? _confirmRequestOf(GoRouterState state) {
  final params = state.uri.queryParameters;
  final requestId = params['request'];
  final courseUnitId = params['unit'];
  final topic = params['topic'];
  if (requestId == null ||
      requestId.isEmpty ||
      courseUnitId == null ||
      courseUnitId.isEmpty ||
      topic == null ||
      topic.isEmpty) {
    return null;
  }
  return (requestId: requestId, courseUnitId: courseUnitId, topic: topic);
}

/// What a link with no id in it gets.
///
/// A sentence rather than a redirect: the link is malformed, and silently
/// sending a student somewhere else would leave them on a screen that has
/// nothing to do with what they asked for and no way to tell that anything went
/// wrong.
class _MissingIdRoute extends StatelessWidget {
  const _MissingIdRoute({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppDimens.lg),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // Reading the controller is what starts the cold-start check of the stored
  // session. It has to happen before the first redirect is evaluated, or the
  // app would hold on splash until something else happened to read it.
  ref.read(authControllerProvider);

  final router = GoRouter(
    initialLocation: AppRoutes.splash,
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.signIn,
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: AppRoutes.signUp,
        builder: (context, state) => const SignUpScreen(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.tutorVerification,
        builder: (context, state) => const SubmitClaimScreen(),
      ),
      GoRoute(
        path: AppRoutes.myApplications,
        builder: (context, state) => const MyApplicationsScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AuthenticatedShell(
          selectedIndex: switch (state.uri.path) {
            AppRoutes.sessions => 1,
            AppRoutes.profile => 2,
            _ => 0,
          },
          child: child,
        ),
        routes: [
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => HomeScreen(
              activeSessionCard: const ActiveSessionCard(),
              tutorRail: const TutorRail(),
              onRefresh: () async {
                ref
                  ..invalidate(sessionListProvider)
                  ..invalidate(topTutorsProvider(null));
                await ref.read(sessionListProvider.future);
              },
            ),
          ),
          GoRoute(
            path: AppRoutes.sessions,
            builder: (context, state) => const SessionsTabScreen(),
          ),
          GoRoute(
            path: AppRoutes.profile,
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '${AppRoutes.sessions}/confirm',
        builder: (context, state) {
          final confirm = _confirmRequestOf(state);
          if (confirm == null) {
            return const _MissingIdRoute(
              title: 'Confirm session',
              message: 'That link does not name a help request.',
            );
          }
          return ConfirmRequestScreen(
            requestId: confirm.requestId,
            courseUnitId: confirm.courseUnitId,
            topic: confirm.topic,
          );
        },
      ),
      GoRoute(
        path: '${AppRoutes.sessions}/:sessionId',
        builder: (context, state) {
          final sessionId = _sessionIdOf(state);
          if (sessionId == null) {
            return const _MissingIdRoute(
              title: 'Session',
              message: 'That link does not name a session.',
            );
          }
          return SessionDetailScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: '${AppRoutes.sessions}/:sessionId/rate',
        builder: (context, state) {
          final sessionId = _sessionIdOf(state);
          if (sessionId == null) {
            return const _MissingIdRoute(
              title: 'Session',
              message: 'That link does not name a session.',
            );
          }
          return RateSessionScreen(sessionId: sessionId);
        },
      ),
      GoRoute(
        path: '${AppRoutes.tutors}/:userId',
        builder: (context, state) {
          final userId = _idOf(state, 'userId');
          if (userId == null) {
            return const _MissingIdRoute(
              title: 'Tutor',
              message: 'That link does not name a tutor.',
            );
          }
          return TutorDetailScreen(userId: userId);
        },
      ),
      GoRoute(
        path: AppRoutes.matching,
        builder: (context, state) => const CourseUnitPickerScreen(),
      ),
      GoRoute(
        path: '${AppRoutes.matching}/:courseUnitId',
        builder: (context, state) {
          final courseUnitId = _idOf(state, 'courseUnitId');
          if (courseUnitId == null) {
            return const _MissingIdRoute(
              title: 'Find a tutor',
              message: 'That link does not name a course unit.',
            );
          }
          return MatchResultsScreen(courseUnitId: courseUnitId);
        },
      ),
      GoRoute(
        path: AppRoutes.tutorRequests,
        builder: (context, state) => const TutorRequestsScreen(),
      ),
      GoRoute(
        path: AppRoutes.certificate,
        builder: (context, state) => const CertificateScreen(),
      ),
    ],
    // go_router re-evaluates this on every navigation and whenever the
    // listenable fires, which is what makes an auth change redirect the app
    // from wherever it is without the screen asking for it.
    refreshListenable: _SessionChangeNotifier(ref),
    redirect: (context, state) => _redirectFor(
      ref.read(sessionControllerProvider),
      state.matchedLocation,
    ),
  );

  ref.onDispose(router.dispose);
  return router;
});

/// The one place that decides where an auth status is allowed to lead.
///
/// Pure and takes the whole session rather than the status alone, because a
/// signed-in student is not automatically allowed home -- one with no name or no
/// university has to run the wizard first. Passing only the status would have
/// forced that distinction back out into every call site.
String? _redirectFor(SessionState state, String location) {
  return switch (state.status) {
    // Nothing is known yet. Stay put only if already waiting; otherwise hold
    // the app on splash rather than guessing and flashing the wrong screen.
    SessionStatus.unknown =>
      location == AppRoutes.splash ? null : AppRoutes.splash,
    // Sign-in and sign-up are both reachable while signed out, and the two must
    // be listed together. Exempting only sign-in made the guard redirect a
    // student off the sign-up screen the instant they arrived, so "No account
    // yet? Create one" did nothing at all: the button navigated, the guard
    // undid it, and the screen never rendered. The screen itself was correct and
    // its widget tests passed, because they pumped it directly and never went
    // through here.
    SessionStatus.unauthenticated =>
      _isPublicAuthRoute(location) ? null : AppRoutes.signIn,
    SessionStatus.authenticated => _redirectForSignedIn(
      state.profile,
      location,
    ),
  };
}

/// The two routes a signed-out student is allowed to be on.
///
/// Shared by both branches of the guard deliberately. The signed-in branch has
/// to reject these and the signed-out branch has to accept them, and writing the
/// pair out separately is how the two halves drifted apart in the first place.
bool _isPublicAuthRoute(String location) =>
    location == AppRoutes.signIn || location == AppRoutes.signUp;

/// Where a signed-in student belongs.
String? _redirectForSignedIn(UserProfile? profile, String location) {
  // Sign-in and sign-up are the two places a signed-in student must not be, or
  // a bookmarked /sign-in link would strand them in a form that cannot succeed.
  if (_isPublicAuthRoute(location)) {
    return _landingFor(profile);
  }

  // `needsOnboarding` is the profile's own answer, so the definition of "still
  // incomplete" exists once, in the model, and not again here.
  final needsOnboarding = profile?.needsOnboarding ?? true;

  if (needsOnboarding) {
    return location == AppRoutes.onboarding ? null : AppRoutes.onboarding;
  }

  if (location == AppRoutes.tutorVerification) {
    return null;
  }

  // The requests a tutor has been chosen for. Allowed here for the same reason as
  // the certificate screen -- the screen asks for this account's own pending
  // requests, and the server filters by the caller -- but without the role check,
  // because the screen has an honest empty state to show an account that is not a
  // tutor yet, and because refusing by role would bounce a tutor whose approval
  // landed between two launches.
  //
  // Without this the guard sends the tutor straight back to the dashboard on
  // arrival: the entry navigates, the guard undoes it, and the tile looks broken.
  // The widget tests never saw it, because they pumped the screen directly and
  // never came through here.
  if (location == AppRoutes.tutorRequests) {
    return null;
  }

  // The whole sessions subtree, not just its two screens. A signed-in student who
  // follows a link to a session, or who is on the rating form for one, is exactly
  // as allowed to be there as one who walked there from home, and the guard that
  // bounced them to the dashboard mid-flow was a redirect with no reason to exist.
  //
  // Tutor profiles and matching are allowed for the same reason and for a second
  // one: they are reached *from* home and from the rail, so a guard that only
  // exempted home and sessions would let a student tap a tutor's card and be
  // returned to the dashboard, which reads as the app refusing to open the thing
  // they just pressed.
  //
  // The certificate screen is allowed for a narrower reason, and it is not the
  // tutor-role check it looks like. It answers about the caller's own hours and
  // only about the caller's, so there is nothing behind it for another account to
  // read -- but the guard cannot ask that, because by the time it runs the screen
  // has not fetched anything. Refusing the route by role would send a tutor whose
  // profile was created between two app launches back to the dashboard, and
  // redirecting everyone else would leave a deep link to a screen that has an
  // honest "you are not a tutor yet" state as the only alternative.
  if (_isSessionRoute(location) ||
      _isTutorRoute(location) ||
      _isMatchingRoute(location) ||
      location == AppRoutes.certificate) {
    return null;
  }

  // Onboarding is not a place a complete account can remain: once the profile
  // is finished the guard moves it home, which is also what ends the wizard
  // after its last step.
  return location == AppRoutes.home ||
          location == AppRoutes.sessions ||
          location == AppRoutes.profile
      ? null
      : AppRoutes.home;
}

/// Whether a location is inside the sessions subtree.
bool _isSessionRoute(String location) =>
    location == AppRoutes.sessions ||
    location.startsWith('${AppRoutes.sessions}/');

/// Whether a location is a tutor profile.
bool _isTutorRoute(String location) =>
    location.startsWith('${AppRoutes.tutors}/');

/// Whether a location is inside the matching subtree.
bool _isMatchingRoute(String location) =>
    location == AppRoutes.matching ||
    location.startsWith('${AppRoutes.matching}/');

String _landingFor(UserProfile? profile) =>
    (profile?.needsOnboarding ?? true) ? AppRoutes.onboarding : AppRoutes.home;

/// Bridges the session to the `Listenable` go_router expects.
///
/// go_router predates Riverpod and has no adapter of its own, so the shell
/// supplies one rather than adding a dependency for a single interface.
class _SessionChangeNotifier extends ChangeNotifier {
  _SessionChangeNotifier(Ref ref) {
    _subscription = ref.listen<SessionState>(
      sessionControllerProvider,
      (previous, next) => notifyListeners(),
    );
  }

  late final ProviderSubscription<SessionState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}
