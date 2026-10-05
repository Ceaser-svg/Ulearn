import 'package:flutter/foundation.dart';

/// A university as the onboarding picker needs it.
///
/// Not the full university type in `core/models/`: that one carries a complete
/// grading scale, because matching needs to compare a tutor's grade against a
/// university's own bar. The picker shows a name, and the list endpoint returns
/// the scale as an identifier, so a narrower type here avoids inventing scale
/// detail the API did not send.
@immutable
class UniversityOption {
  const UniversityOption({
    required this.publicId,
    required this.name,
    this.gradingScaleId,
    this.isFallback = false,
  });

  factory UniversityOption.fromJson(Map<String, dynamic> json) {
    return UniversityOption(
      publicId: json['id'] as String,
      name: json['name'] as String,
      gradingScaleId: json['grading_scale_id'] as String?,
    );
  }

  final String publicId;

  final String name;

  final String? gradingScaleId;

  final bool isFallback;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UniversityOption &&
          other.publicId == publicId &&
          other.name == name &&
          other.gradingScaleId == gradingScaleId &&
          other.isFallback == isFallback;

  @override
  int get hashCode => Object.hash(publicId, name, gradingScaleId, isFallback);

  @override
  String toString() => 'UniversityOption($publicId, $name)';
}
