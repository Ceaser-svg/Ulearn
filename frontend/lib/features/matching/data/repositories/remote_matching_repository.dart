import 'package:dio/dio.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit.dart';
import 'package:peerpass/core/network/network_exceptions.dart';
import 'package:peerpass/features/matching/data/datasources/remote_matching_datasource.dart';
import 'package:peerpass/features/matching/data/models/help_request.dart';
import 'package:peerpass/features/matching/data/models/match_result.dart';
import 'package:peerpass/features/matching/data/repositories/matching_repository.dart';

/// [MatchingRepository] over the real API.
///
/// The only layer that knows both the wire format and the failure hierarchy. The
/// `_guard` helper below is the same shape as the one in
/// `remote_sessions_repository.dart`, duplicated rather than lifted into `core/`:
/// hoisting it means editing files this feature does not own.
class RemoteMatchingRepository implements MatchingRepository {
  const RemoteMatchingRepository(this._remote);

  final RemoteMatchingDatasource _remote;

  @override
  Future<List<CourseUnit>> courseUnits({
    String? universityId,
    String? subjectId,
  }) => _guard(
    () => _remote.courseUnits(universityId: universityId, subjectId: subjectId),
  );

  @override
  Future<MatchResult> suggestions({
    required String courseUnitId,
    bool widenToSubject = false,
    int? limit,
  }) {
    // The parse runs inside the guard: a response that is not the shape the API
    // documents is a server fault, and a `fromJson` that ran outside would
    // throw past every translation here and reach the screen as a bare
    // `FormatException`.
    return _guard(
      () async => MatchResult.fromJson(
        await _remote.suggestions(
          courseUnitId: courseUnitId,
          widenToSubject: widenToSubject,
          limit: limit,
        ),
      ),
    );
  }

  @override
  Future<List<HelpRequest>> myHelpRequests() {
    return _guard(
      () async => [
        for (final row in await _remote.myHelpRequests())
          HelpRequest.fromJson(row),
      ],
    );
  }

  @override
  Future<HelpRequest> createHelpRequest({
    required String courseUnitId,
    required String topic,
    String? description,
  }) {
    return _guard(
      () async => HelpRequest.fromJson(
        await _remote.createHelpRequest(
          courseUnitId: courseUnitId,
          topic: topic,
          description: description,
        ),
      ),
    );
  }

  @override
  Future<HelpRequest> selectTutor({
    required String requestId,
    required String candidateTutorId,
  }) {
    return _guard(
      () async => HelpRequest.fromJson(
        await _remote.selectTutor(
          requestId: requestId,
          candidateTutorId: candidateTutorId,
        ),
      ),
    );
  }

  @override
  Future<List<HelpRequest>> requestsAwaitingMe() {
    // Each row is parsed inside the guard rather than in a `map` outside it: one
    // unreadable row is a server fault, and a `fromJson` that threw past the
    // translation here would reach the screen as a bare `FormatException`.
    return _guard(
      () async => [
        for (final row in await _remote.requestsAwaitingMe())
          HelpRequest.fromJson(row),
      ],
    );
  }

  @override
  Future<HelpRequest> declineHelpRequest({required String requestId}) {
    return _guard(
      () async => HelpRequest.fromJson(
        await _remote.declineHelpRequest(requestId: requestId),
      ),
    );
  }

  /// Runs a call and translates whatever comes back into a [Failure].
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on Object catch (error) {
      throw _toFailure(error);
    }
  }

  Failure _toFailure(Object error) {
    if (error is Failure) return error;
    if (error is FormatException) {
      return const ServerFailure(
        'The server sent something we could not read.',
      );
    }
    if (error is DioException) return mapDioException(error);
    return const UnknownFailure();
  }
}
