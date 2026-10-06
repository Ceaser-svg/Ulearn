import 'package:dio/dio.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/network/network_exceptions.dart';
import 'package:peerpass/features/competencies/data/datasources/remote_competencies_datasource.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';
import 'package:peerpass/features/competencies/data/repositories/competencies_repository.dart';

/// [CompetenciesRepository] over the real API.
///
/// The one place that translates transport faults into [Failure], so the screens
/// behind it render a message and never show raw exception text. A
/// [FormatException] is reported as a server fault rather than an unknown one,
/// because that is what it is: the API answered with a body this client cannot
/// read, and no tutor can act on it either way.
class RemoteCompetenciesRepository implements CompetenciesRepository {
  const RemoteCompetenciesRepository({required this.datasource});

  final RemoteCompetenciesDatasource datasource;

  @override
  Future<List<TutorClaim>> myClaims() => _guard(datasource.myClaims);

  @override
  Future<TutorClaim> submitClaim({
    required String courseUnitId,
    required String gradeId,
    required String source,
    String? evidenceReference,
    String? notes,
  }) => _guard(
    () => datasource.submit(
      courseUnitId: courseUnitId,
      gradeId: gradeId,
      source: source,
      evidenceReference: evidenceReference,
      notes: notes,
    ),
  );

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
