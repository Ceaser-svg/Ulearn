import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';

/// A review the API refused, in words an operator can act on.
///
/// Thrown rather than returned so the screen cannot accidentally render a
/// success for a refusal: the previous version returned an outcome enum with a
/// `failed` case, which meant the failure path was one `if` away from the success
/// path and every caller had to remember to check it.
class AdminReviewException implements Exception {
  const AdminReviewException(this.message);

  final String message;

  @override
  String toString() => 'AdminReviewException: $message';
}

/// Records competency reviews.
///
/// The console's one write, and the one place a button used to call the API
/// directly. Every failure is translated here, because an operator's next move
/// differs per cause: a validation refusal is fixed by choosing something else, a
/// missing credential by signing in again, and a dropped connection by trying
/// again. Reporting all three as "could not record the review" told the operator
/// none of that.
final competencyReviewControllerProvider = Provider<CompetencyReviewController>(
  (ref) => CompetencyReviewController(ref.watch(adminRepositoryProvider)),
);

class CompetencyReviewController {
  const CompetencyReviewController(this._repository);

  final AdminRepository _repository;

  /// Verifies a competency.
  ///
  /// The API refuses a grade below the university's threshold, which the operator
  /// cannot see on the console without knowing the scale. That refusal arrives as a
  /// [AdminReviewException] carrying the API's own wording, which names the
  /// threshold -- so this is a message about the university's scale arriving from
  /// the server that owns it, not a rule reimplemented here.
  Future<void> verify(AdminCompetency competency) =>
      _review(competency, 'verified');

  /// Rejects a competency with a reason the tutor can act on.
  Future<void> reject(AdminCompetency competency, String reason) =>
      _review(competency, 'rejected', reason: reason);

  Future<void> _review(
    AdminCompetency competency,
    String status, {
    String? reason,
  }) async {
    try {
      await _repository.reviewCompetency(competency, status, reason: reason);
    } on DioException catch (error) {
      throw AdminReviewException(_describe(error));
    }
  }

  /// The operator-facing wording for a failed request.
  ///
  /// Reads the API's problem document where there is one, and falls back to a
  /// named cause otherwise. Never the exception itself: a Dio message can carry a
  /// URL, and this string is rendered in a snack bar.
  String _describe(DioException error) {
    switch (error.type) {
      case DioExceptionType.transformTimeout:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The server took too long to respond. Try again.';
      case DioExceptionType.connectionError:
        return 'Could not reach the server. Check the connection and try again.';
      case DioExceptionType.badCertificate:
        return "The server's certificate was rejected. This is a security "
            'problem, not a problem with this review.';
      case DioExceptionType.cancel:
        return 'The review was cancelled.';
      case DioExceptionType.badResponse:
        return _describeStatus(
          error.response?.statusCode,
          error.response?.data,
        );
      case DioExceptionType.unknown:
        return 'The review could not be recorded. Try again.';
    }
  }

  String _describeStatus(int? status, Object? body) {
    // A missing status means the request never got an answer, which is a
    // transport fault rather than a refusal the API expressed.
    if (status == null) return 'The review could not be recorded. Try again.';
    final detail = _detailOf(body);
    final fields = _fieldErrorsOf(body);

    return switch (status) {
          // The API's own wording, which for a verification refusal is the only place
          // the university's threshold is stated.
          400 || 422 =>
            detail ??
                'The competency could not be reviewed with these details.',
          401 =>
            'Your session has expired. Sign in again to continue reviewing.',
          403 => 'You are not permitted to review competencies.',
          404 => detail ?? 'That competency no longer exists. It may have been reviewed already.',
          409 => detail ?? 'This review conflicts with the current state.',
          429 => 'Too many attempts. Wait a moment and try again.',
          final int code when code >= 500 =>
            detail ??
                'The server could not record the review. Try again shortly.',
          _ => detail ?? 'The review could not be recorded. Try again.',
        }.trimRight() +
        _suffix(fields);
  }

  /// Appends the per-field reasons to a validation message.
  ///
  /// `status: requires 4.5 or higher on the MUST scale` is the part an operator
  /// needs when the top-level detail only says the competency could not be
  /// reviewed, and the API puts it in `errors` rather than in `detail`.
  String _suffix(Map<String, String> fields) {
    if (fields.isEmpty) return '';
    final rendered = fields.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('; ');
    return '\n\n$rendered';
  }

  String? _detailOf(Object? body) {
    if (body is! Map<String, dynamic>) return null;
    final detail = body['detail'];
    if (detail is! String || detail.isEmpty) return null;
    return detail;
  }

  Map<String, String> _fieldErrorsOf(Object? body) {
    if (body is! Map<String, dynamic>) return const {};
    final errors = body['errors'];
    if (errors is! Map<String, dynamic>) return const {};
    return {
      for (final entry in errors.entries)
        if (entry.value is String) entry.key: entry.value as String,
    };
  }
}
