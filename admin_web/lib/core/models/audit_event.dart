/// One privileged action, as `/v1/admin/audit-events` describes it.
///
/// The log is append-only and read-only here: an operator reads it, they do
/// not curate it.
class AuditEvent {
  const AuditEvent({
    required this.actorId,
    required this.actorEmail,
    required this.actorName,
    required this.action,
    required this.targetType,
    required this.targetPublicId,
    required this.context,
    required this.createdAt,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> json) => AuditEvent(
    actorId: json['actor_id'] as String,
    actorEmail: json['actor_email'] as String,
    actorName: json['actor_name'] as String?,
    action: json['action'] as String,
    targetType: json['target_type'] as String,
    targetPublicId: json['target_public_id'] as String?,
    context: (json['context'] as Map<String, dynamic>?) ?? const {},
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String actorId;

  /// Who acted, in the form an operator would say it.
  ///
  /// Read through the join rather than copied onto the event, so a corrected
  /// name is reflected instead of contradicted.
  final String actorEmail;
  final String? actorName;
  final String action;
  final String targetType;
  final String? targetPublicId;
  final Map<String, dynamic> context;
  final DateTime createdAt;

  /// The actor as a person rather than as an identifier.
  ///
  /// A bare UUID cannot answer "who did this", which is the only question an
  /// audit log exists to answer. The email is the fallback because a staff
  /// account created without a full name is a real state, not an error.
  String get actorLabel =>
      actorName == null || actorName!.isEmpty ? actorEmail : actorName!;
}
