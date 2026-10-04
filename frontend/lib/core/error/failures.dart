import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// Transport-independent representation of an error.
///
/// The presentation layer renders [Failure] and never a `DioException`, an
/// `SocketException`, or an HTTP status code. That keeps the UI unaware of Dio
/// and means swapping the HTTP client does not ripple into every screen.
///
/// [core/network/network_exceptions.dart] is responsible for translating
/// transport errors into these types. Because the hierarchy is sealed, an
/// exhaustive `switch` over a failure is a compile error when a new variant is
/// added, which is the point: adding a failure type should force every
/// presentation site to decide how to show it.
///
/// Implements [Exception] because these are thrown across the data/presentation
/// boundary and caught by screen code. A hierarchy that is thrown but is not an
/// [Exception] breaks the convention every `catch` and `on` clause in the
/// codebase relies on, and makes the lints that guard that convention fire at
/// every throw site.
sealed class Failure implements Exception {
  const Failure(this.message);

  /// Message safe to show to a user.
  ///
  /// Transport detail and stack information must not reach this field; it is
  /// rendered verbatim in the UI.
  final String message;
}

/// The request never reached the server, or the connection dropped.
///
/// Retryable by nature. Distinguishable from [ServerFailure] because the
/// remedy is different: this one succeeds on a second attempt from the same
/// device.
final class NetworkFailure extends Failure {
  const NetworkFailure([
    super.message = 'No connection. Check your network and try again.',
  ]);
}

/// Credentials are missing, expired, or insufficient for the operation.
///
/// Not retryable without re-authenticating first.
final class AuthFailure extends Failure {
  const AuthFailure([
    super.message = 'Your session has ended. Please sign in again.',
  ]);
}

/// The server rejected the submitted values.
///
/// [fieldErrors] maps a form field name to the reason it was rejected, so a form
/// can render the message next to the input that caused it.
@immutable
final class ValidationFailure extends Failure {
  const ValidationFailure(super.message, {this.fieldErrors = const {}});

  /// Per-field rejection reasons, keyed by the field name the API used.
  final Map<String, String> fieldErrors;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValidationFailure &&
          other.message == message &&
          _mapEquals(other.fieldErrors, fieldErrors);

  @override
  int get hashCode => Object.hash(
    message,
    Object.hashAllUnordered(
      fieldErrors.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

/// The requested resource does not exist, or is not visible to this user.
final class NotFoundFailure extends Failure {
  const NotFoundFailure([super.message = 'That item could not be found.']);
}

/// The request collided with existing state.
///
/// Raised when accepting a session that was already accepted or completed, which
/// is expected on a mobile client where a retried request is normal.
final class ConflictFailure extends Failure {
  const ConflictFailure([
    super.message = 'That has already changed. Refresh and try again.',
  ]);
}

/// The server failed to handle an otherwise valid request.
final class ServerFailure extends Failure {
  const ServerFailure([super.message = 'Something went wrong on our end.']);
}

/// The caller is being rate limited: too many attempts, too soon.
///
/// Its own type rather than a [ServerFailure] or [ConflictFailure] because it is
/// the one failure where retrying *now* is guaranteed to fail again, and the one
/// where the caller has been told how long to wait. That makes it the only
/// failure with a scheduled remedy, and the presentation layer needs to be able
/// to act on the wait rather than on the wording.
///
/// A lockout must never be reported as an authentication problem: a client that
/// treats 429 as 401 signs the student out and loses the sign-in form they were
/// standing on. A distinct type makes that collapse a compile error.
@immutable
final class ThrottledFailure extends Failure {
  const ThrottledFailure(super.message, {this.retryAfter, this.retryAt});

  /// How long the server asked the caller to wait, when it said.
  ///
  /// Null when the response carried no usable `Retry-After`, which is legal --
  /// a proxy can strip the header. The UI then says nothing about timing rather
  /// than inventing a number the server never promised.
  final Duration? retryAfter;

  /// The instant the wait ends, captured when the failure was built.
  ///
  /// Absolute rather than a duration so a countdown can recompute against the
  /// clock without being told twice how long the wait was, and so a widget that
  /// rebuilds does not restart the wait. Null when the server said nothing
  /// usable, in which case there is nothing to count down.
  final DateTime? retryAt;

  /// Whether trying again now could plausibly succeed.
  bool get isWaitOver {
    final at = retryAt;
    return at == null || !clock.now().isBefore(at);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThrottledFailure &&
          other.message == message &&
          other.retryAfter == retryAfter &&
          other.retryAt == retryAt;

  @override
  int get hashCode => Object.hash(message, retryAfter, retryAt);
}

/// A request was cancelled before it completed, usually by navigation.
final class CancelledFailure extends Failure {
  const CancelledFailure([super.message = 'Request cancelled.']);
}

/// An error with no more specific classification.
///
/// Kept as a distinct type rather than collapsing into [ServerFailure] so that
/// "we do not know what this was" stays visible in logs rather than being
/// reported as a server fault.
final class UnknownFailure extends Failure {
  const UnknownFailure([super.message = 'Something unexpected happened.']);
}

/// The failure a screen may render for [error].
///
/// The one crossing point between "something was thrown" and "something is
/// shown". A repository is contracted to throw a [Failure], but a provider can
/// still fail with something that is not one -- a repository override that was
/// never registered is the case that happens in practice, and every test that
/// does not care about the feature hits it. The [Failure] hierarchy is what the
/// UI is written against, so anything else becomes an [UnknownFailure] here
/// rather than being rendered. Without it a missing override would put
/// `UnimplementedError: sessionsRepositoryProvider must be overridden in
/// ProviderScope.` on a student's home screen.
///
/// In `core/` rather than beside the first feature that needed it, because three
/// features reach for it and the alternative was a copy per feature.
Failure failureFor(Object error) =>
    error is Failure ? error : const UnknownFailure();

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
