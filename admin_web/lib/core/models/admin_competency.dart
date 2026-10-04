/// A tutor competency awaiting or completing review, as
/// `/v1/admin/competencies` describes it.
///
/// The review fields staff need, without the submitted evidence document
/// itself: the console shows the reference an auditor can follow up on, not
/// the document it points at.
class AdminCompetency {
  const AdminCompetency({
    required this.id,
    required this.email,
    required this.name,
    required this.unit,
    required this.grade,
    required this.status,
    required this.evidence,
  });

  factory AdminCompetency.fromJson(Map<String, dynamic> json) =>
      AdminCompetency(
        id: json['id'] as String,
        email: json['user_email'] as String,
        name: json['user_name'] as String?,
        unit: '${json['course_unit_code']} - ${json['course_unit_name']}',
        grade: json['grade_points'] as String,
        status: json['status'] as String,
        evidence: json['evidence_reference'] as String?,
      );

  final String id;
  final String email;
  final String? name;
  final String unit;
  final String grade;
  final String status;
  final String? evidence;
}
