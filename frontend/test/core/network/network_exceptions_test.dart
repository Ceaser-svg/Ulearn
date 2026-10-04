import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/network/network_exceptions.dart';

/// Builds a 401-shaped problem details response.
Response<dynamic> problemResponse(int status, Object? body) {
  final options = RequestOptions(path: '/test');
  return Response<dynamic>(
    requestOptions: options,
    statusCode: status,
    data: body,
  );
}

/// Builds a 429-shaped response carrying the header this API sends.
Response<dynamic> throttledResponse({
  String detail = 'Too many attempts. Try again shortly.',
  String? retryAfter,
}) {
  final options = RequestOptions(path: '/test');
  return Response<dynamic>(
    requestOptions: options,
    statusCode: 429,
    data: {
      'detail': detail,
      if (retryAfter != null) 'errors': {'retry_after_seconds': int.tryParse(retryAfter)},
    },
    headers: retryAfter == null
        ? Headers()
        : Headers.fromMap({'retry-after': [retryAfter]}),
  );
}

void main() {
  group('mapDioException on transport errors', () {
    test('maps a connection timeout to a retryable network failure', () {
      final failure = mapDioException(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });

    test('maps a dropped connection to a network failure', () {
      final failure = mapDioException(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionError,
          error: const SocketException('failed'),
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });

    test('maps a cancellation to its own failure, not an error', () {
      final failure = mapDioException(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.cancel,
        ),
      );

      expect(failure, isA<CancelledFailure>());
    });

    test('maps an unrecognised socket error to a network failure', () {
      final failure = mapDioException(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          // `unknown` is Dio's default type, which is exactly the case under
          // test here: the cause is only visible in `error`.
          error: const SocketException('unreachable'),
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });

    test('maps an unparseable response to a server failure', () {
      final failure = mapDioException(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          error: const FormatException('bad json'),
        ),
      );

      expect(failure, isA<ServerFailure>());
    });
  });

  group('mapDioException on problem details responses', () {
    test('maps 400 to a validation failure', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 400,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(400, const {'detail': 'Bad input'}),
        ),
      );

      expect(failure, isA<ValidationFailure>());
    });

    test('surfaces per-field errors so a form can show them inline', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 422,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(422, const {
            'detail': 'Some fields are invalid',
            'errors': {'email': 'Enter a valid email address'},
          }),
        ),
      );

      expect(failure, isA<ValidationFailure>());
      expect((failure as ValidationFailure).fieldErrors, {
        'email': 'Enter a valid email address',
      });
    });

    test('maps 401 and 403 to an auth failure', () {
      for (final status in [401, 403]) {
        final failure = mapDioException(
          DioException.badResponse(
            statusCode: status,
            requestOptions: RequestOptions(path: '/test'),
            response: problemResponse(status, const {'detail': 'Nope'}),
          ),
        );

        expect(failure, isA<AuthFailure>(), reason: 'status $status');
      }
    });

    test('maps 404 to not found', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(404, const {'detail': 'No tutor'}),
        ),
      );

      expect(failure, isA<NotFoundFailure>());
    });

    test('maps 409 to a conflict', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 409,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(409, const {'detail': 'Already accepted'}),
        ),
      );

      expect(failure, isA<ConflictFailure>());
    });

    test('maps 429 to a throttled failure, never to unknown', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '900'),
        ),
      );

      expect(failure, isA<ThrottledFailure>());
      expect(failure.message, isNot(contains('unexpected')));
    });

    test('maps 429 to a lockout rather than an auth failure', () {
      // The regression this case exists for. A 429 reaching the client as an
      // AuthFailure signs the student out and loses the form they are standing
      // on, which is the opposite of what a rate limit should do.
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '60'),
        ),
      );

      expect(failure, isNot(isA<AuthFailure>()));
      expect(failure, isNot(isA<UnknownFailure>()));
    });

    test('reads the wait from the Retry-After header', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '900'),
        ),
      );

      expect((failure as ThrottledFailure).retryAfter, const Duration(seconds: 900));
    });

    test('falls back to errors.retry_after_seconds when the header is gone', () {
      // A proxy may strip the header while passing the body through untouched.
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(429, const {
            'detail': 'Too many attempts.',
            'errors': {'retry_after_seconds': 120},
          }),
        ),
      );

      expect(
        (failure as ThrottledFailure).retryAfter,
        const Duration(seconds: 120),
      );
    });

    test('prefers the Retry-After header over the body field when they disagree', () {
      // The header is what RFC 6585 mandates and what an intermediary would
      // honour, so it wins. A body field left behind by an older build must not
      // shorten the wait the server actually asked for.
      final options = RequestOptions(path: '/test');
      final response = Response<dynamic>(
        requestOptions: options,
        statusCode: 429,
        data: const {
          'detail': 'Too many attempts.',
          'errors': {'retry_after_seconds': 60},
        },
        headers: Headers.fromMap({
          'retry-after': ['900'],
        }),
      );

      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: options,
          response: response,
        ),
      );

      expect(
        (failure as ThrottledFailure).retryAfter,
        const Duration(seconds: 900),
      );
    });

    test('accepts an HTTP-date Retry-After', () {
      final when = DateTime.now().add(const Duration(minutes: 5));
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: HttpDate.format(when)),
        ),
      );

      expect(
        (failure as ThrottledFailure).retryAfter,
        isNotNull,
        reason: 'the date form must not degrade to an unknown error',
      );
    });

    test('clamps an absurd Retry-After instead of counting to it', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '99999999'),
        ),
      );

      expect(
        (failure as ThrottledFailure).retryAfter,
        const Duration(hours: 1),
      );
    });

    test('treats a negative Retry-After as no wait at all', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '-5'),
        ),
      );

      expect((failure as ThrottledFailure).retryAfter, Duration.zero);
    });

    test('still reports a throttle when the server said no wait', () {
      // Legal: a proxy can strip both the header and the field. Saying nothing
      // about timing is honest; reporting an unknown error is not.
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(429, const {
            'detail': 'Too many attempts. Try again shortly.',
          }),
        ),
      );

      expect(failure, isA<ThrottledFailure>());
      expect((failure as ThrottledFailure).retryAfter, isNull);
    });

    test('uses the API wording when it carried no usable wait', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(429, const {
            'detail': 'Too many attempts. Try again shortly.',
          }),
        ),
      );

      expect(failure.message, 'Too many attempts. Try again shortly.');
    });

    test('names the wait instead of the API vaguer wording', () {
      // "Try again shortly" is true and useless to someone told to wait a
      // quarter of an hour, and this is where that difference is visible.
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '900'),
        ),
      );

      expect(failure.message, contains('15 minutes'));
    });

    test('says a minute in words rather than as a number of seconds', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 429,
          requestOptions: RequestOptions(path: '/test'),
          response: throttledResponse(retryAfter: '60'),
        ),
      );

      expect(failure.message, contains('a minute'));
    });

    test('maps any 5xx to a server failure', () {
      for (final status in [500, 502, 503]) {
        final failure = mapDioException(
          DioException.badResponse(
            statusCode: status,
            requestOptions: RequestOptions(path: '/test'),
            response: problemResponse(status, const {'detail': 'Boom'}),
          ),
        );

        expect(failure, isA<ServerFailure>(), reason: 'status $status');
      }
    });

    test('maps an unexpected status to unknown, not server', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 418,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(418, const {'detail': 'Teapot'}),
        ),
      );

      expect(failure, isA<UnknownFailure>());
    });

    test('prefers the problem detail over the generic status message', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(404, const {'detail': 'Tutor was removed'}),
        ),
      );

      expect(failure.message, 'Tutor was removed');
    });

    test(
      'falls back to a safe message when the body is not problem details',
      () {
        final failure = mapDioException(
          DioException.badResponse(
            statusCode: 500,
            requestOptions: RequestOptions(path: '/test'),
            response: problemResponse(500, '<html>Bad Gateway</html>'),
          ),
        );

        expect(failure, isA<ServerFailure>());
        expect(failure.message, isNot(contains('<html>')));
      },
    );

    test('ignores non-string field errors rather than coercing them', () {
      final failure = mapDioException(
        DioException.badResponse(
          statusCode: 422,
          requestOptions: RequestOptions(path: '/test'),
          response: problemResponse(422, const {
            'errors': {
              'tags': ['too many', 'not allowed'],
            },
          }),
        ),
      );

      expect((failure as ValidationFailure).fieldErrors, isEmpty);
    });
  });
}
