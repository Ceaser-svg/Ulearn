import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:peerpass/core/error/failures.dart';

/// Translates a transport error into a [Failure].
///
/// The only place in the client that knows Dio or `SocketException` exist.
/// Everything above this boundary works in terms of [Failure], which is what
/// lets the presentation layer stay free of HTTP concerns.
Failure mapDioException(DioException exception) {
  return switch (exception.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.transformTimeout => const NetworkFailure(
      'The server took too long to respond. Try again.',
    ),
    DioExceptionType.connectionError => const NetworkFailure(),
    DioExceptionType.cancel => const CancelledFailure(),
    DioExceptionType.badCertificate => const NetworkFailure(
      'Could not establish a secure connection to the server.',
    ),
    DioExceptionType.badResponse => _mapResponse(exception.response),
    DioExceptionType.unknown => _mapUnknown(exception),
  };
}

/// A response that carried a status the client did not accept.
///
/// The API answers errors with RFC 9457 problem details, where `detail` is
/// human-readable text and `title` is a short summary. Classification keys off
/// the HTTP status rather than the `code` member: the status is the contract
/// this layer must handle exhaustively, whereas a problem `code` is free to be
/// added to without a client change.
Failure _mapResponse(Response<dynamic>? response) {
  if (response == null) {
    return const NetworkFailure();
  }

  final status = response.statusCode;
  if (status == null) {
    return const UnknownFailure();
  }

  final message = _problemDetail(response.data);
  final fieldErrors = _fieldErrors(response.data);

  return switch (status) {
    400 || 422 => ValidationFailure(
      message ?? 'Some of the details you entered are not valid.',
      fieldErrors: fieldErrors,
    ),
    // The API's detail is preferred, and it matters here: the same 401 answers a
    // wrong password and an expired token, and the student needs to be told
    // which. Hardcoding "your session has ended" made a mistyped password look
    // like a sign-out, which sends them to a sign-in screen they are already on.
    401 || 403 => AuthFailure(
      message ??
          (status == 401
              ? 'Email or password is incorrect.'
              : 'You do not have access to that.'),
    ),
    404 => NotFoundFailure(message ?? 'That item could not be found.'),
    409 => ConflictFailure(
      message ?? 'That has already changed. Refresh and try again.',
    ),
    429 => _throttled(response, message),
    >= 500 => ServerFailure(
      message ?? 'Something went wrong on our end. Please try again.',
    ),
    _ => UnknownFailure(message ?? 'Something unexpected happened.'),
  };
}

/// A lockout, carrying how long to wait.
///
/// The message is composed here rather than taken from the API, because this is
/// the one failure where the server's own wording is not the useful part. The
/// API says "try again shortly", which is true and useless to a student who has
/// been told to wait fifteen minutes -- and this is the surface where that
/// difference is visible. The API's text is still used when it carried no usable
/// wait, because then it is all there is.
///
/// Falling through to `UnknownFailure` here is the bug this case exists to fix:
/// a deliberate, documented rate limit was being reported to students as
/// "something unexpected happened", which is both untrue and unactionable.
Failure _throttled(Response<dynamic>? response, String? message) {
  final wait = _retryAfter(response);

  if (wait == null) {
    return ThrottledFailure(
      message ?? 'Too many attempts. Wait a moment before trying again.',
    );
  }

  return ThrottledFailure(
    'Too many attempts. Try again in ${_humanize(wait)}.',
    retryAfter: wait,
    retryAt: DateTime.now().add(wait),
  );
}

/// The wait the server asked for, or null if it did not say.
///
/// Read from the `Retry-After` header, falling back to the problem document's
/// own `errors.retry_after_seconds`. The header comes first because it is what
/// RFC 6585 mandates and what any intermediary would honour; the body field is
/// the fallback because this API emits both and a proxy may strip the header
/// while passing the body through untouched.
Duration? _retryAfter(Response<dynamic>? response) {
  final fromBody = _retryAfterFromBody(response?.data);
  final fromHeader = _retryAfterFromHeader(response?.headers.value('retry-after'));

  return fromHeader ?? fromBody;
}

/// Header value in either of the two forms RFC 6585 allows.
///
/// Delta-seconds is what this API sends. The HTTP-date form is accepted anyway:
/// a client that silently treats a date as unparseable reports a fifteen-minute
/// lockout as an unknown error, and the whole cost of that mistake is paid by
/// whoever got locked out.
Duration? _retryAfterFromHeader(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty) return null;

  final seconds = int.tryParse(value);
  if (seconds != null) return _bounded(Duration(seconds: seconds));

  // `HttpDate.parse` throws on anything unparseable and has no `tryParse`, so
  // the second form is guarded explicitly.
  final DateTime when;
  try {
    when = HttpDate.parse(value);
  } on FormatException {
    return null;
  }

  final remaining = when.difference(DateTime.now());
  return remaining.isNegative ? Duration.zero : _bounded(remaining);
}

/// `errors.retry_after_seconds` from the problem document, when it is an integer.
Duration? _retryAfterFromBody(Object? body) {
  if (body is! Map<String, dynamic>) return null;

  final errors = body['errors'];
  if (errors is! Map<String, dynamic>) return null;

  final seconds = errors['retry_after_seconds'];
  if (seconds is int) return _bounded(Duration(seconds: seconds));

  // A proxy or a hand-written client may have re-encoded the number as a
  // string. Accepting it costs nothing; the alternative is a silent null.
  if (seconds is String) {
    final parsed = int.tryParse(seconds.trim());
    if (parsed != null) return _bounded(Duration(seconds: parsed));
  }

  return null;
}

/// Rejects a wait the client could not honour.
///
/// A negative or absurdly long value is a server bug, and the one thing that
/// must not happen is a UI that shows "try again in 4473 minutes" because a
/// proxy rewrote the header. Clamped rather than discarded: a long real lockout
/// still deserves an honest countdown.
Duration _bounded(Duration wait) {
  const ceiling = Duration(hours: 1);
  if (wait.isNegative) return Duration.zero;
  if (wait > ceiling) return ceiling;
  return wait;
}

/// A duration as a phrase a person would say.
///
/// One minute is not "60 seconds", and under a minute is not "45 seconds" in a
/// banner somebody is meant to read rather than parse.
String _humanize(Duration wait) {
  if (wait.inSeconds < 60) return '${wait.inSeconds} seconds';
  if (wait.inMinutes == 1) return 'a minute';
  return '${wait.inMinutes} minutes';
}

/// The human-readable part of a problem details document, if it is one.
///
/// Returns null for any body that is not a problem details object, so a proxy
/// error page or an empty body falls through to the status-based default
/// message instead of being shown verbatim.
String? _problemDetail(Object? body) {
  if (body is! Map<String, dynamic>) return null;

  final detail = body['detail'];
  if (detail is! String || detail.isEmpty) return null;

  return detail;
}

/// The per-field errors in a problem details document, keyed by field name.
///
/// A form uses this to render each rejection next to the input that caused it.
/// Entries whose value is not a string are dropped rather than coerced, since
/// rendering `[object Object]` as a validation message helps nobody.
Map<String, String> _fieldErrors(Object? body) {
  if (body is! Map<String, dynamic>) return const {};

  final errors = body['errors'];
  if (errors is! Map<String, dynamic>) return const {};

  return {
    for (final entry in errors.entries)
      if (entry.value is String) entry.key: entry.value as String,
  };
}

/// An error with no response, where the cause is only visible in the inner
/// error. `SocketException` is separated out because "no connection" and
/// "certificate rejected" need different wording even though Dio reports both
/// as an unknown error.
Failure _mapUnknown(DioException exception) {
  final cause = exception.error;

  if (cause is SocketException) {
    return const NetworkFailure();
  }
  if (cause is TimeoutException) {
    return const NetworkFailure('The server took too long to respond.');
  }
  if (cause is FormatException) {
    return const ServerFailure('The server sent a response we could not read.');
  }

  return const UnknownFailure();
}
