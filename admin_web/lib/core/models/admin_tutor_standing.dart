/// A tutor's operational standing, as `/v1/admin/tutor-standings` describes
/// it.
///
/// An aggregate, not a decision: the backend owns what a standing means and
/// how it is reached, so the console only reads and labels it.
class AdminTutorStanding {
  const AdminTutorStanding({
    required this.email,
    required this.name,
    required this.standing,
    required this.sessions,
    required this.rating,
  });

  factory AdminTutorStanding.fromJson(Map<String, dynamic> json) =>
      AdminTutorStanding(
        email: json['user_email'] as String,
        name: json['user_name'] as String?,
        standing: json['standing'] as String,
        sessions: json['completed_sessions'] as int,
        rating: json['average_rating'] as String?,
      );

  final String email;
  final String? name;
  final String standing;
  final int sessions;
  final String? rating;
}
