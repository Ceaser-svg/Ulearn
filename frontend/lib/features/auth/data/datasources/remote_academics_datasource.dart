import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/features/auth/data/models/university_option.dart';

/// Reads the reference data the onboarding wizard offers.
///
/// Unauthenticated on purpose. Sign-up asks a stranger where they study, before
/// there is anything to authenticate as, so requiring a token here would leave
/// the first screen of the app unreachable.
class RemoteAcademicsDatasource {
  const RemoteAcademicsDatasource(this._dio);

  final Dio _dio;

  Future<List<UniversityOption>> universities() async {
    final response = await _dio.get<List<dynamic>>(
      '/v1/academics/universities',
    );
    return [
      for (final row in response.data!)
        UniversityOption.fromJson(row as Map<String, dynamic>),
    ];
  }

  /// The faculties, in alphabetical order.
  ///
  /// The API models a faculty as a `Subject`, because that is what groups course
  /// units, and the wizard offers the units in the faculty a student picked. The
  /// client does not rename it: calling the same rows "subjects" here would mean
  /// the wizard and the API disagree about the word for the same thing.
  ///
  /// Not filtered by university, because the API does not filter it. A faculty is
  /// a property of a course unit rather than of an institution, so the list is
  /// global while the pilot is a single institution.
  Future<List<Subject>> faculties({required String universityId}) async {
    final response = await _dio.get<List<dynamic>>(
      '/v1/academics/faculties',
      queryParameters: {'university_id': universityId},
    );
    return [
      for (final row in response.data!)
        Subject(
          publicId: (row as Map<String, dynamic>)['id'] as String,
          name: row['name'] as String,
        ),
    ];
  }

  /// Course units for the given university, for the primary modules step.
  ///
  /// Filtered by university so a student only sees units from their own
  /// institution. The API accepts an optional `university_id` query param.
  Future<List<CourseUnitOption>> courseUnits({
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
      for (final row in response.data!)
        CourseUnitOption.fromJson(row as Map<String, dynamic>),
    ];
  }

  /// Grades for the selected university's published scale.
  Future<List<GradeOption>> grades({String? universityId}) async {
    final response = await _dio.get<List<dynamic>>(
      '/v1/academics/grades',
      queryParameters: {'university_id': universityId},
    );
    return [
      for (final row in response.data!)
        GradeOption.fromJson(row as Map<String, dynamic>),
    ];
  }
}

/// A course unit as returned from the academics reference endpoint.
@immutable
class CourseUnitOption {
  const CourseUnitOption({
    required this.publicId,
    required this.code,
    required this.name,
  });

  factory CourseUnitOption.fromJson(Map<String, dynamic> json) =>
      CourseUnitOption(
        publicId: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
      );

  final String publicId;
  final String code;
  final String name;
}

/// A grade on a university's published scale.
@immutable
class GradeOption {
  const GradeOption({
    required this.publicId,
    required this.label,
    required this.gradePoints,
  });

  factory GradeOption.fromJson(Map<String, dynamic> json) => GradeOption(
    publicId: json['id'] as String,
    label: json['label'] as String,
    gradePoints: (json['grade_points'] as num).toDouble(),
  );

  final String publicId;
  final String label;
  final double gradePoints;
}
