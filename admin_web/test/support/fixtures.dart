import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_tutor_standing.dart';
import 'package:peerpass_admin/core/models/admin_user.dart';
import 'package:peerpass_admin/core/models/audit_event.dart';

/// Builds a pilot user for a fake console or a JSON fixture.
AdminUser adminUserFixture({
  required String email,
  String? name,
  List<String> roles = const <String>['student'],
  bool isActive = true,
  String createdAt = '2026-01-01T09:00:00Z',
}) => AdminUser(
  email: email,
  name: name,
  roles: roles,
  isActive: isActive,
  createdAt: DateTime.parse(createdAt),
);

/// Builds an audit event for a fake console or a JSON fixture.
AuditEvent auditEventFixture({
  required String action,
  String targetType = 'user',
  String createdAt = '2026-01-02T10:30:00Z',
}) => AuditEvent(
  action: action,
  targetType: targetType,
  createdAt: DateTime.parse(createdAt),
);

/// Builds a competency for a fake console or a JSON fixture.
AdminCompetency competencyFixture({
  String id = 'competency-1',
  String email = 'tutor@peerpass.test',
  String? name = 'Grace Tutor',
  String status = 'pending',
  String? evidence = 'transcript-2026.pdf',
}) => AdminCompetency(
  id: id,
  email: email,
  name: name,
  unit: 'CS301 - Algorithms',
  grade: 'B+',
  status: status,
  evidence: evidence,
);

/// Builds a tutor standing for a fake console or a JSON fixture.
AdminTutorStanding tutorStandingFixture({
  required String email,
  String? name = 'Grace Tutor',
  String standing = 'verified',
  int sessions = 12,
  String? rating = '4.80',
}) => AdminTutorStanding(
  email: email,
  name: name,
  standing: standing,
  sessions: sessions,
  rating: rating,
);

/// A `Page` envelope, as the backend serves one.
Map<String, dynamic> pageJson({
  required List<Map<String, dynamic>> items,
  required int total,
  int limit = 50,
  int offset = 0,
}) => <String, dynamic>{
  'items': items,
  'total': total,
  'limit': limit,
  'offset': offset,
  'has_more': offset + items.length < total,
  'page_count': limit <= 0 ? 0 : (total / limit).ceil(),
};

/// One user, as the backend serves one.
Map<String, dynamic> userJson({
  String email = 'ada@peerpass.test',
  String? fullName = 'Ada Lovelace',
  List<String> roles = const <String>['student', 'tutor'],
  bool isActive = true,
  String createdAt = '2026-01-01T09:00:00Z',
}) => <String, dynamic>{
  'id': '0f6c1c5a-0000-4000-8000-000000000001',
  'email': email,
  'full_name': fullName,
  'roles': roles,
  'university_id': null,
  'faculty_id': null,
  'year_of_study': null,
  'is_active': isActive,
  'created_at': createdAt,
};

/// A sign-in body, as the backend serves one.
Map<String, dynamic> loginJson({
  String email = 'operator@peerpass.test',
  List<String> roles = const <String>['admin'],
  String accessToken = 'access-token',
  String refreshToken = 'refresh-token',
}) => <String, dynamic>{
  'tokens': <String, dynamic>{
    'access_token': accessToken,
    'refresh_token': refreshToken,
  },
  'user': <String, dynamic>{'id': 'id', 'email': email, 'roles': roles},
};
