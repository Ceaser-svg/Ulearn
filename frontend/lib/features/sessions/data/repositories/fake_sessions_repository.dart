import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/sessions/data/models/rating_model.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/data/repositories/sessions_repository.dart';

/// In-memory stand-in for the session and rating endpoints.
///
/// What widget tests resolve, because a widget test has no server to talk to. It
/// implements the repository's shape rather than the datasource's, because that
/// is the seam a test cares about: overriding the repository is the only
/// composition the app supports.
///
/// It is a fake and not a stub: the handshake really compares pins and the wrong
/// one really fails, the pin really moves the session to in-progress, and a rating
/// really marks the session rated. A fake that returned whatever it was given would
/// let a screen that never shows the failure -- or shows the wrong one -- pass.
class FakeSessionsRepository implements SessionsRepository {
  FakeSessionsRepository({
    List<SessionModel> sessions = const [],
    Map<String, int> pinFailures = const {},
  }) : _sessions = List<SessionModel>.of(sessions),
       _pinFailures = Map<String, int>.of(pinFailures) {
    // Every session the API creates is issued a PIN, so seeded ones get one too.
    // Otherwise a tutor-side screen test would fail on "no PIN" for a reason that
    // has nothing to do with what it is testing.
    for (final session in _sessions) {
      _pins.putIfAbsent(session.id, () => '42');
    }
  }

  final List<SessionModel> _sessions;

  /// Handshake pins, keyed by session id.
  ///
  /// Held here rather than on [SessionModel] because that is where the API keeps
  /// it too: the pin is not part of a session payload, so a session built from
  /// fake wire data has no pin until one is issued for it.
  final Map<String, String> _pins = <String, String>{};

  /// Wrong entries per session, so the fake can mirror the API's ceiling.
  final Map<String, int> _pinFailures;

  /// The ceiling the fake enforces. Mirrors `MAX_PIN_ATTEMPTS` server-side.
  static const int maxPinAttempts = 5;

  /// The tutee a confirmed session is attributed to.
  ///
  /// Set by [withPendingStudent] rather than invented at the point of use, so a
  /// test that confirms a request can assert the resulting session belongs to the
  /// student who asked rather than to nobody.
  String _pendingTuteeId = 'student-1';

  /// The tutor a confirmed session is attributed to.
  String _pendingTutorId = 'tutor-1';

  /// The sessions the API would return, newest first.
  List<SessionModel> get sessions => List<SessionModel>.unmodifiable(_sessions);

  /// Every rating submitted through this repository, in order.
  ///
  /// A test asserts on this to check what the rate screen actually sent, which is
  /// the only way to catch a screen that shows a score and submits a different
  /// one.
  final List<RatingModel> submittedRatings = [];

  /// The endorsed course unit ids of every submission, in order.
  ///
  /// Separate from [submittedRatings] because `RatingResponse` does not echo the
  /// endorsements back -- they are not part of the rating row -- so a test that
  /// only read the returned rating could not tell whether the endorsement went out
  /// at all.
  final List<List<String>> endorsementSubmissions = [];

  /// Every pin submitted through [verifyPin], in order.
  ///
  /// Kept so a test can prove a rejected pin was actually sent rather than
  /// refused by the client, and that a second attempt was still allowed.
  final List<String> pinAttempts = [];

  /// The sessions passed to [endSession], in order.
  final List<String> endedSessionIds = [];

  /// What every [confirmRequest] was called with, in order.
  ///
  /// Recorded rather than inferred from the created session, so a test can assert
  /// on the duration the tutor actually typed. The created session echoes it, but
  /// only because this fake set it that way -- which is the thing under suspicion.
  final List<
    ({String requestId, String courseUnitId, String topic, int durationMinutes})
  >
  confirmations = [];

  /// Confirms a request the way the API does: refused unless it names a session
  /// that is already confirmed for that request.
  ///
  /// The refusal is modelled rather than stubbed because a double confirmation is
  /// the failure a phone actually produces, and a fake that always succeeded would
  /// let a screen ship a button that can be tapped twice into two sessions.
  @override
  Future<SessionModel> confirmRequest({
    required String requestId,
    required String courseUnitId,
    required String topic,
    required int durationMinutes,
  }) async {
    confirmations.add((
      requestId: requestId,
      courseUnitId: courseUnitId,
      topic: topic,
      durationMinutes: durationMinutes,
    ));

    final index = _sessions.indexWhere(
      (session) => session.helpRequestId == requestId,
    );
    if (index != -1) {
      throw const ConflictFailure(
        'This help request is not waiting for your answer.',
      );
    }
    if (durationMinutes < 1) {
      throw const ValidationFailure(
        'That length is not one the API accepts.',
        fieldErrors: {'duration_minutes': 'must be at least 1'},
      );
    }

    final created = SessionModel.fromJson({
      'id': 'session-from-$requestId',
      'tutee_id': _pendingTuteeId,
      'tutor_id': _pendingTutorId,
      'course_unit_id': courseUnitId,
      'course_unit_code': 'MAT 221',
      'course_unit_name': 'Linear Algebra',
      'tutee_name': 'Adongo Sarah',
      'tutor_name': 'Okello Daniel',
      'topic': topic,
      'status': 'scheduled',
      'duration_minutes': durationMinutes,
      'is_rated': false,
      'created_at': '2026-03-01T08:00:00Z',
      'help_request_id': requestId,
    });
    _sessions.add(created);
    _pins[created.id] = '42';
    return created;
  }

  /// Points the fake's confirmed sessions at a student and tutor.
  ///
  /// Returns nothing rather than `this`: a builder returning itself invites
  /// `FakeSessionsRepository()..withPendingStudent(...)` at a call site that then
  /// reads as though the value were new.
  void withPendingStudent(String tuteeId, {String? tutorId}) {
    _pendingTuteeId = tuteeId;
    if (tutorId != null) _pendingTutorId = tutorId;
  }

  @override
  Future<List<SessionModel>> sessionsForMe() async => sessions;

  @override
  Future<SessionModel> session(String sessionId) async => _require(sessionId);

  @override
  Future<SessionPinModel> revealPin({required String sessionId}) async {
    final pin = _pins[sessionId];
    if (pin == null) {
      throw const ValidationFailure('This session has no handshake PIN.');
    }
    return SessionPinModel(
      sessionId: sessionId,
      sessionPin: pin,
      attemptsRemaining: maxPinAttempts - (_pinFailures[sessionId] ?? 0),
    );
  }

  @override
  Future<SessionModel> verifyPin({
    required String sessionId,
    required String pin,
  }) async {
    pinAttempts.add(pin);

    final session = _require(sessionId);
    final expected = _pins[sessionId];
    final failures = _pinFailures[sessionId] ?? 0;

    // Fails closed the way the API does: a session with no stored pin rejects
    // every candidate, including a blank one.
    if (expected == null || expected.isEmpty || pin.trim() != expected) {
      final updatedFailures = failures + 1;
      _pinFailures[sessionId] = updatedFailures;
      if (updatedFailures >= maxPinAttempts) {
        throw ThrottledFailure(
          'Too many wrong PIN attempts. Try again later.',
          retryAfter: const Duration(minutes: 15),
          retryAt: DateTime.now().add(const Duration(minutes: 15)),
        );
      }
      throw const ValidationFailure(
        'The session PIN is incorrect.',
        fieldErrors: {'pin': 'incorrect'},
      );
    }

    // Reset on success, as the API does, so one typo does not leave a tutee a
    // try away from a lockout.
    _pinFailures.remove(sessionId);

    return _replace(
      session.copyWith(
        status: TutoringSessionStatus.inProgress,
        statusWire: TutoringSessionStatus.inProgress.wireValue,
      ),
    );
  }

  @override
  Future<SessionModel> endSession(String sessionId) async {
    endedSessionIds.add(sessionId);
    return _replace(
      _require(sessionId).copyWith(
        status: TutoringSessionStatus.completed,
        statusWire: TutoringSessionStatus.completed.wireValue,
      ),
    );
  }

  @override
  Future<RatingModel> rateSession({
    required String sessionId,
    required int score,
    String? feedbackText,
    List<String> endorsedCourseUnitIds = const [],
  }) async {
    final session = _require(sessionId);

    final rating = RatingModel(
      id: 'rating-$sessionId',
      sessionId: sessionId,
      // The API fills the rater and ratee in from the session rather than trusting
      // the body, so the fake derives them the same way: a tutee rates their
      // tutor, never the other way round.
      raterId: session.tuteeId,
      rateeId: session.tutorId,
      score: score,
      feedbackText: feedbackText,
      createdAt: DateTime.utc(2026, 3, 4, 9),
    );
    submittedRatings.add(rating);
    endorsementSubmissions.add(List<String>.of(endorsedCourseUnitIds));

    _replace(session.copyWith(isRated: true));
    return rating;
  }

  /// The session with [sessionId], or a failure the way the API would.
  SessionModel _require(String sessionId) {
    for (final session in _sessions) {
      if (session.id == sessionId) return session;
    }
    throw const NotFoundFailure('That session could not be found.');
  }

  /// Swaps a stored session for the version the API would now return.
  SessionModel _replace(SessionModel updated) {
    final index = _sessions.indexWhere((session) => session.id == updated.id);
    if (index != -1) _sessions[index] = updated;
    return updated;
  }
}
