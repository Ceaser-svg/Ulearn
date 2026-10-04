/// One privileged action, as `/v1/admin/audit-events` describes it.
///
/// The log is append-only and read-only here: an operator reads it, they do
/// not curate it.
class AuditEvent {
  const AuditEvent({
    required this.actorId,
    required this.action,
    required this.targetType,
    required this.targetPublicId,
    required this.context,
    required this.createdAt,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> json) => AuditEvent(
    actorId: json['actor_id'] as String,
    action: json['action'] as String,
    targetType: json['target_type'] as String,
    targetPublicId: json['target_public_id'] as String?,
    context: (json['context'] as Map<String, dynamic>?) ?? const {},
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String actorId;
  final String action;
  final String targetType;
  final String? targetPublicId;
  final Map<String, dynamic> context;
  final DateTime createdAt;
}
