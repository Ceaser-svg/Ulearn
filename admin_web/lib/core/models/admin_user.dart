/// A pilot user, as `/v1/admin/users` describes it.
///
/// Only the fields staff need to operate: the identifiers and the academic
/// context behind them are deliberately absent from this shape, so there is
/// nothing for the console to display by accident.
class AdminUser {
  const AdminUser({
    required this.email,
    required this.name,
    required this.roles,
    required this.isActive,
    required this.createdAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    email: json['email'] as String,
    name: json['full_name'] as String?,
    roles: (json['roles'] as List<dynamic>).cast<String>(),
    isActive: json['is_active'] as bool,
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String email;
  final String? name;
  final List<String> roles;
  final bool isActive;
  final DateTime createdAt;
}
