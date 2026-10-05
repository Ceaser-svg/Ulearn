import 'package:flutter/foundation.dart';

import 'package:peerpass/core/models/json_decimal.dart';

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
    gradePoints: readRequiredDecimal(json['grade_points'], 'grade_points'),
  );

  final String publicId;
  final String label;
  final double gradePoints;
}
