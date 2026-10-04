import 'package:dio/dio.dart';
import 'package:peerpass/core/models/course_unit.dart';

/// Talks to `/v1/matching` and reads the course-unit catalogue the picker offers.
///
/// Covers the help requests that live under the same prefix, because a help
/// request is how a student asks to be matched and a request this feature cannot
/// create is a feature the student cannot use. The confirm step -- the tutor
/// accepting, which creates a session -- is deliberately absent: a session is the
/// sessions feature's resource and its repository owns creating one, and this
/// feature reaching over to `POST /v1/sessions` would be two features writing one
/// endpoint.
///
/// Throws [DioException], not a `Failure`. Classification belongs to
/// `core/network/network_exceptions.dart` and happens once, in the repository,
/// so a socket error and an RFC 9457 problem document are translated by the same
/// code whichever endpoint produced them.
class RemoteMatchingDatasource {
  const RemoteMatchingDatasource(this._dio);

  final Dio _dio;

  /// The course units a student can pick, for their own university.
  ///
  /// Read here rather than reused from the auth feature's academics datasource.
  /// The dependency rules let one feature reach another only through that
  /// feature's repository contract, so a datasource shared by two features would
  /// need a home outside `features/` -- and `core/` is not where an HTTP call
  /// about course units belongs. The same endpoint is called twice in the app's
  /// life, once per flow, and the duplication is the cheaper of the two.
  Future<List<CourseUnit>> courseUnits({
    String? universityId,
    String? subjectId,
  }) async {
    final response = await _dio.get<List<dynamic>>(
      '/v1/academics/course-units',
      queryParameters: {
        'university_id': ?universityId,
        'subject_id': ?subjectId,
      },
    );
    return [
      for (final row in response.data ?? const <dynamic>[])
        CourseUnit(
          publicId: (row as Map<String, dynamic>)['id'] as String,
          code: row['code'] as String,
          name: row['name'] as String,
        ),
    ];
  }

  /// Asks who may take this course unit.
  ///
  /// The unit-only route. The request-backed one, `/help-requests/{id}/matches`,
  /// answers about a help request the caller owns and would make the caller
  /// create one first; this client sends the unit it was given, and the response
  /// comes back with `request_id` null because nothing backs the query.
  ///
  /// Three fields, exactly. `MatchRequest` is a `RequestSchema`, which forbids
  /// unknown keys: sending a `request_id` the client did not receive, or any
  /// other extra, is a 422 rather than something ignored. [limit] is left at the
  /// API's own bound unless a caller asks for fewer, so "as many as the platform
  /// will propose" is decided in one place.
  Future<Map<String, dynamic>> suggestions({
    required String courseUnitId,
    required bool widenToSubject,
    int? limit,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/matching/suggestions',
      data: <String, dynamic>{
        'course_unit_id': courseUnitId,
        'widen_to_subject': widenToSubject,
        'limit': ?limit,
      },
    );
    return response.data!;
  }

  /// The requests this student created.
  ///
  /// The only way this client can learn what became of a request it made. The
  /// matching response carries candidate tutors and no request status, so a
  /// student waiting on a chosen tutor cannot be told "they declined" by anything
  /// in this file's other calls -- and a screen that kept saying "not yet
  /// confirmed" after the API had recorded a decline would be telling a student
  /// something false about the one thing they asked.
  Future<List<Map<String, dynamic>>> myHelpRequests() async {
    final response = await _dio.get<List<dynamic>>(
      '/v1/matching/help-requests/me',
    );
    return [
      for (final row in response.data ?? const <dynamic>[])
        if (row is Map<String, dynamic>) row,
    ];
  }

  /// Asks for help with a course unit, naming the specific question.
  ///
  /// [topic] is not optional because the API requires it, and because "MAT 221"
  /// is a course while "eigenvalues" is the question a tutor has to agree to
  /// before the request is worth anything to either of them.
  ///
  /// [description] is sent only when the student gave one. `HelpRequestCreate` is
  /// a `RequestSchema`, which forbids unknown keys but does not forbid an absent
  /// optional one, and sending `"description": null` would be this client
  /// asserting the student wrote nothing rather than that they had the chance to.
  Future<Map<String, dynamic>> createHelpRequest({
    required String courseUnitId,
    required String topic,
    String? description,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/matching/help-requests',
      data: <String, dynamic>{
        'course_unit_id': courseUnitId,
        'topic': topic,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );
    return response.data!;
  }

  /// Names the tutor this request should wait on.
  ///
  /// One field, named `candidate_tutor_id` rather than `tutor_id` because the API
  /// refuses a plainly-named user id in a request body -- a spelling that reads as
  /// a primary key that leaked onto the wire. What the field selects is the
  /// column the response calls `matched_tutor_id`.
  ///
  /// Two calls and not one: the request has to exist before a tutor can be named
  /// against it, and composing them here would mean a screen that got halfway
  /// through had to know which half it was in.
  Future<Map<String, dynamic>> selectTutor({
    required String requestId,
    required String candidateTutorId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/matching/help-requests/$requestId/select',
      data: <String, dynamic>{'candidate_tutor_id': candidateTutorId},
    );
    return response.data!;
  }

  /// The requests that named the signed-in tutor and are waiting on their answer.
  ///
  /// A list rather than a single object because the API scopes it by the tutor and
  /// returns what is outstanding, and because a client that fetched "the one"
  /// would have to invent which one that is.
  Future<List<Map<String, dynamic>>> requestsAwaitingMe() async {
    final response = await _dio.get<List<dynamic>>(
      '/v1/matching/help-requests/awaiting-me',
    );
    return [
      for (final row in response.data ?? const <dynamic>[])
        if (row is Map<String, dynamic>) row,
    ];
  }

  /// Turns down a request that is waiting on the signed-in tutor.
  ///
  /// No body, and that is not an omission: the decision is entirely the tutor's,
  /// so there is nothing for them to say beyond making it.
  Future<Map<String, dynamic>> declineHelpRequest({
    required String requestId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/matching/help-requests/$requestId/decline',
    );
    return response.data!;
  }
}
