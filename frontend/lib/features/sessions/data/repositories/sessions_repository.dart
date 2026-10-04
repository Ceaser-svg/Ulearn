import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/sessions/data/models/rating_model.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';

/// The tutoring-session contract the screens depend on.
///
/// Every method throws a [Failure], never a transport exception and never a
/// `FormatException`. Translating `DioException`, problem documents, and
/// unparseable bodies into [Failure] happens in the implementation, so a screen
/// renders a message and never has to know whether the API answered with a socket
/// error, a 400, or a body that was not the shape it documents.
///
/// Deliberately narrow. Session cancellation and the tutor rating summary are
/// the API's but have no screen in this release: cancellation needs a reason from
/// the user and its own confirmation journey, and a tutor's rating summary is a
/// separate screen about their own record rather than one of these. Adding either
/// is a screen first and a method second.
abstract interface class SessionsRepository {
  /// Every session the signed-in user is part of, in the order the API returns.
  Future<List<SessionModel>> sessionsForMe();

  /// One session by public id.
  Future<SessionModel> session(String sessionId);

  /// The handshake pin the tutor reads out, with the attempts the tutee has left.
  ///
  /// The tutor's half only. The tutee asking for this is refused by the API, and
  /// it must stay that way: a tutee who could read their own pin would have
  /// nothing to prove, and the tutor no way to tell an in-person student from
  /// someone guessing two digits on a borrowed account.
  Future<SessionPinModel> revealPin({required String sessionId});

  /// Supplies the handshake pin, and returns the session as it now stands.
  ///
  /// A wrong pin is a `ValidationFailure` naming `pin`; the session is left
  /// untouched. Throttling is the API's concern: the client counts no attempts
  /// and locks nobody out, because a lock-out enforced on a device is one a
  /// student clears by reinstalling the app.
  Future<SessionModel> verifyPin({required String sessionId, required String pin});

  /// Confirms a help request the student named this tutor on, and returns the
  /// session that confirmation created.
  ///
  /// The one way a session comes into being. It is not a general "create a
  /// session" on purpose: the API accepts this only for a request that already
  /// names the caller and is waiting on an answer, so a tutor cannot open a
  /// session against work nobody asked them for, and cannot confirm a second
  /// request the student never chose them for.
  ///
  /// [topic] and [courseUnitId] are what the request already says, passed
  /// through rather than re-derived. The API checks the unit against the request
  /// and refuses a mismatch, and it is the only place that answer can be trusted,
  /// so a client that put its own unit here would be refused rather than believed.
  ///
  /// A request the student has since abandoned, or that another confirmation
  /// already took, comes back as a `ConflictFailure`. A lost race is a conflict
  /// and not a crash: the session is created by a unique constraint on the
  /// request, and two taps on a phone produce two requests for one answer.
  Future<SessionModel> confirmRequest({
    required String requestId,
    required String courseUnitId,
    required String topic,
    required int durationMinutes,
  });

  /// Ends a live session, returning it as completed.
  Future<SessionModel> endSession(String sessionId);

  /// Records the score the signed-in user gives for a session, and returns it.
  ///
  /// The API treats a second rating for the same session as an update rather than
  /// a second rating, so a student who changes their mind does not need a second
  /// screen to correct the first.
  ///
  /// [endorsedCourseUnitIds] is the other half of the same submission: a claim
  /// that the tutor actually covered those units, as separate from the score. It
  /// is optional and empty by default on purpose -- an empty list is a legitimate
  /// submission, and a client that could not express it would push people into
  /// endorsing to get past a form. The API accepts only the session's own course
  /// unit and refuses anything else, so this is the unit the session was booked
  /// for and nothing a client chose freely.
  Future<RatingModel> rateSession({
    required String sessionId,
    required int score,
    String? feedbackText,
    List<String> endorsedCourseUnitIds = const [],
  });
}

/// The sessions contract, as a live instance.
///
/// Declared in the contract file rather than beside the sessions screens, for the
/// same reason `authRepositoryProvider` is: this is the handle by which other
/// features reach this feature, and a provider living in `presentation/` could
/// not be imported by a sibling feature without also importing its screens.
///
/// Throwing rather than defaulting keeps a missing override loud. A silent fake
/// default would let a build ship pointed at nothing -- and it is the failure this
/// provider exists to make visible, since the composition root in `main.dart` is
/// what has to name the real implementation.
final sessionsRepositoryProvider = Provider<SessionsRepository>(
  (ref) => throw UnimplementedError(
    'sessionsRepositoryProvider must be overridden in ProviderScope.',
  ),
);
