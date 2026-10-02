import 'package:dio/dio.dart';

/// Talks to the `/v1/sessions` and `/v1/ratings` endpoints the screens use.
///
/// Throws [DioException], not a `Failure`. Classification belongs to
/// `core/network/network_exceptions.dart` and happens once, in the repository, so
/// a socket error and an RFC 9457 problem document are translated by the same
/// code whichever endpoint produced them. Bodies come back as raw JSON on purpose:
/// the repository is where the wire shape becomes a model, so there is one place
/// to look when the two disagree.
class RemoteSessionsDatasource {
  const RemoteSessionsDatasource(this._dio);

  final Dio _dio;

  /// Every session the signed-in user is part of, newest first.
  ///
  /// One request rather than a page per status: the API returns the caller's
  /// whole history in its own order, and the sessions screen only groups what
  /// comes back. Asking the server to pre-sort or pre-filter would be a second
  /// place where "active" is defined.
  Future<List<Map<String, dynamic>>> sessionsForMe() async {
    final response = await _dio.get<List<dynamic>>('/v1/sessions/me');
    return (response.data ?? const <dynamic>[]).whereType<Map<String, dynamic>>().toList();
  }

  /// One session, re-read by public id.
  Future<Map<String, dynamic>> session(String sessionId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/sessions/$sessionId',
    );
    return response.data!;
  }

  /// Moves a session to a new state.
  ///
  /// Only the target state is sent. The API validates the move against its own
  /// transition table and records who made it, so a client cannot assert a status
  /// it was not entitled to reach, and cannot name a different actor.
  Future<Map<String, dynamic>> transition(
    String sessionId, {
    required String status,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/sessions/$sessionId/transition',
      data: <String, dynamic>{'status': status},
    );
    return response.data!;
  }

  /// Creates the session that a tutor confirmed a help request into.
  ///
  /// The request id is in the body rather than the path because the resource
  /// being created is a session, not a sub-resource of the request: the API
  /// refuses the call unless the request is one this tutor was named on and is
  /// still waiting, so the request id identifies *what is being confirmed* rather
  /// than naming the created thing.
  ///
  /// [courseUnitId] is sent because the API requires it, and the API then checks
  /// it against the request's own unit -- a mismatch is refused rather than
  /// trusted. `topic` is the student's own question as the tutor read it on the
  /// request; it is what the session is titled in both apps, so it is not left to
  /// the client to invent and not reworded into something the student did not ask.
  Future<Map<String, dynamic>> createFromRequest(
    String requestId, {
    required String courseUnitId,
    required String topic,
    required int durationMinutes,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/sessions',
      data: <String, dynamic>{
        'help_request_id': requestId,
        'course_unit_id': courseUnitId,
        'topic': topic,
        'duration_minutes': durationMinutes,
      },
    );
    return response.data!;
  }

  /// Reads the two-digit handshake pin the tutor has to read aloud.
  ///
  /// Tutor-only, and it is a separate call rather than a field on the session:
  /// the pin lives in a payload both parties could otherwise fetch, which would
  /// leave the tutee able to read their own and skip the handshake entirely.
  Future<Map<String, dynamic>> revealPin(String sessionId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/v1/sessions/$sessionId/pin',
    );
    return response.data!;
  }

  /// Submits the two-digit handshake pin for a session.
  ///
  /// The dedicated route rather than a transition carrying the pin, because it is
  /// the only move whose precondition is a secret and it deserves a path that says
  /// so. The API answers a wrong pin with a 422 naming the `pin` field, and leaves
  /// the session scheduled. A 429 means the attempts are spent and the API, not
  /// this client, decides when trying again is allowed.
  Future<Map<String, dynamic>> verifyPin(
    String sessionId,
    String pin,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/sessions/$sessionId/verify-pin',
      data: <String, dynamic>{'pin': pin},
    );
    return response.data!;
  }

  /// Creates or updates the rating the signed-in user gives for a session.
  ///
  /// The session comes from the path, never from the body, so a client cannot
  /// rate a session it was not part of by sending someone else's id.
  Future<Map<String, dynamic>> submitRating(
    String sessionId, {
    required int score,
    String? feedbackText,
    List<String> endorsedCourseUnitIds = const [],
  }) async {
    final data = <String, dynamic>{'score': score};
    // Only sent when there is something to say. A null `feedback_text` would be
    // read as "clear whatever was stored", which is not what an untouched field
    // on a re-submit means.
    if (feedbackText != null) data['feedback_text'] = feedbackText;
    // The endorsements are sent as the API wants them: a list, absent when there is
    // nothing to claim. Note that "absent" and "empty" are the *same request* here
    // -- `RatingCreate.endorsed_course_unit_ids` defaults to an empty list, so
    // omitting the key arrives server-side as `[]`. That is not a way of leaving an
    // existing endorsement alone: the service replaces the set on every
    // submission, so an empty list withdraws what was there. Nothing this client
    // can do about it -- `RatingResponse` does not echo a rater's own endorsements,
    // so there is nowhere to read back what would be withdrawn. The rating screen
    // says so on a re-submission instead of letting it happen quietly.
    if (endorsedCourseUnitIds.isNotEmpty) {
      data['endorsed_course_unit_ids'] = endorsedCourseUnitIds;
    }

    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/ratings/$sessionId',
      data: data,
    );
    return response.data!;
  }
}
