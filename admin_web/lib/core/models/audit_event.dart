/// One privileged action, as `/v1/admin/audit-events` describes it.
///
/// The log is append-only and read-only here: an operator reads it, they do
/// not curate it.
class AuditEvent {
  const AuditEvent({
    required this.action,
    required this.targetType,
    required this.createdAt,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> json) => AuditEvent(
    action: json['action'] as String,
    targetType: json['target_type'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String action;
  final String targetType;
  final DateTime createdAt;
}
