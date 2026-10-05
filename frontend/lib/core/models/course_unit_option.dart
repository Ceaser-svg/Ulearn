import 'package:flutter/foundation.dart';

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
