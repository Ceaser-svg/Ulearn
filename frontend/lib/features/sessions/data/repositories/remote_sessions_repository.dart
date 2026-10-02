import 'package:dio/dio.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/network/network_exceptions.dart';
import 'package:peerpass/features/sessions/data/datasources/remote_sessions_datasource.dart';
import 'package:peerpass/features/sessions/data/models/rating_model.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/data/repositories/sessions_repository.dart';

/// [SessionsRepository] over the real API.
///
/// The only layer that knows both the wire format and the failure hierarchy. The
/// `_guard` helper below is the same shape as the one in
/// `remote_auth_repository.dart`, duplicated rather than lifted into `core/`:
/// hoisting it means editing a file this feature does not own, and a third copy
/// is the point at which it should move to `core/network/`.
class RemoteSessionsRepository implements SessionsRepository {
  const RemoteSessionsRepository(this._remote);

  final RemoteSessionsDatasource _remote;

  @override
  Future<List<SessionModel>> sessionsForMe() {
    // The whole body is inside the guard, including the parse. A malformed
    // response is a server fault, and a `fromJson` that ran after the guard
    // returned would throw past every translation here and reach the screen as a
    // bare `FormatException`.
    return _guard(() async {
      final bodies = await _remote.sessionsForMe();
      return bodies.map(SessionModel.fromJson).toList();
    });
  }

  @override
  Future<SessionModel> session(String sessionId) =>
      _guard(() async => SessionModel.fromJson(await _remote.session(sessionId)));

  @override
  Future<SessionPinModel> revealPin({required String sessionId}) {
    return _guard(() async => SessionPinModel.fromJson(await _remote.revealPin(sessionId)));
  }

  @override
  Future<SessionModel> verifyPin({
    required String sessionId,
    required String pin,
  }) {
    return _guard(
      () async =>
          SessionModel.fromJson(await _remote.verifyPin(sessionId, pin)),
    );
  }

  @override
  Future<SessionModel> confirmRequest({
    required String requestId,
    required String courseUnitId,
    required String topic,
    required int durationMinutes,
  }) {
    return _guard(
      () async => SessionModel.fromJson(
        await _remote.createFromRequest(
          requestId,
          courseUnitId: courseUnitId,
          topic: topic,
          durationMinutes: durationMinutes,
        ),
      ),
    );
  }

  @override
  Future<SessionModel> endSession(String sessionId) {
    return _guard(
      () async => SessionModel.fromJson(
        await _remote.transition(sessionId, status: 'completed'),
      ),
    );
  }

  @override
  Future<RatingModel> rateSession({
    required String sessionId,
    required int score,
    String? feedbackText,
    List<String> endorsedCourseUnitIds = const [],
  }) {
    return _guard(
      () async => RatingModel.fromJson(
        await _remote.submitRating(
          sessionId,
          score: score,
          feedbackText: feedbackText,
          endorsedCourseUnitIds: endorsedCourseUnitIds,
        ),
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
      // The API answered with something that is not the shape it documents.
      // Reported as a server fault rather than an unknown one, because that is
      // what it is, and a student cannot act on it either way.
      return const ServerFailure(
        'The server sent something we could not read.',
      );
    }
    if (error is DioException) return mapDioException(error);
    return const UnknownFailure();
  }
}
