import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/competency_review_controller.dart';

import '../../../../support/fake_admin_repository.dart';
import '../../../../support/fixtures.dart';

/// A refused request carrying the problem document the API sends.
DioException _problem(int status, [Object? body]) => DioException(
  requestOptions: RequestOptions(path: '/v1/admin/competencies/c1/review'),
  type: DioExceptionType.badResponse,
  response: Response<dynamic>(
    requestOptions: RequestOptions(path: '/v1/admin/competencies/c1/review'),
    statusCode: status,
    data: body,
  ),
);

/// A request that never reached the API.
DioException _transport(DioExceptionType type) => DioException(
  requestOptions: RequestOptions(path: '/v1/admin/competencies/c1/review'),
  type: type,
  error: 'no route to host',
);

void main() {
  late FakeAdminRepository repository;
  late CompetencyReviewController controller;

  setUp(() {
    repository = FakeAdminRepository();
    controller = CompetencyReviewController(repository);
  });

  group('a review that worked', () {
    test('sends the decision the operator chose', () async {
      await controller.verify(competencyFixture());

      expect(repository.reviews.single.status, 'verified');
      expect(repository.reviews.single.reason, isNull);
    });

    test('sends the reason the operator typed with a rejection', () async {
      await controller.reject(
        competencyFixture(),
        'The transcript does not name the course.',
      );

      expect(repository.reviews.single.status, 'rejected');
      expect(
        repository.reviews.single.reason,
        'The transcript does not name the course.',
      );
    });
  });

  group('what a refusal tells the operator', () {
    test('a grade below the threshold reports the threshold', () async {
      // The console has no grade scale, so the API's wording is the only place an
      // operator can learn what "verified" required. Passing it through is the
      // whole reason this mapping exists; a generic message would make a correct
      // refusal look like a bug.
      repository.reviewError = _problem(422, {
        'title': 'Validation failed',
        'status': 422,
        'detail':
            'This grade is below the competency threshold for the university, '
            'so it cannot be verified.',
        'errors': {'status': 'requires 4.5 or higher on the MUST scale'},
      });

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('below the competency threshold'),
              contains('requires 4.5 or higher on the MUST scale'),
            ),
          ),
        ),
      );
    });

    test('a missing reason reports the API wording', () async {
      repository.reviewError = _problem(422, {
        'status': 422,
        'detail': 'A rejection reason is required.',
        'errors': {'rejection_reason': 'required when rejecting'},
      });

      await expectLater(
        controller.reject(competencyFixture(), 'x'),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('A rejection reason is required.'),
              contains('rejection_reason: required when rejecting'),
            ),
          ),
        ),
      );
    });

    test('an expired session says to sign in again', () async {
      // Distinct from every other failure on purpose: signing in is the remedy
      // here and nothing else is, so reporting it as a server fault sends the
      // operator to refresh a page that will keep failing.
      repository.reviewError = _problem(401, {'status': 401});

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            contains('Sign in again'),
          ),
        ),
      );
    });

    test('a forbidden call does not claim the session expired', () async {
      repository.reviewError = _problem(403, {'status': 403});

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(contains('not permitted'), isNot(contains('Sign in'))),
          ),
        ),
      );
    });

    test('a record that is gone says so', () async {
      // Usually means a second operator reviewed it first. Reported as itself
      // rather than as a retryable fault, so the operator refreshes the list
      // instead of pressing Verify again.
      repository.reviewError = _problem(404, {
        'status': 404,
        'detail': 'That competency record could not be found.',
      });

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            contains('could not be found'),
          ),
        ),
      );
    });

    test('a lockout says to wait rather than to retry', () async {
      repository.reviewError = _problem(429, {
        'status': 429,
        'detail': 'Too many requests',
      });

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(contains('Too many'), contains('Wait')),
          ),
        ),
      );
    });

    test(
      'a server fault does not claim the operator did something wrong',
      () async {
        repository.reviewError = _problem(500, {'status': 500});

        await expectLater(
          controller.verify(competencyFixture()),
          throwsA(
            isA<AdminReviewException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('server'),
                isNot(contains('could not be reviewed with these details')),
              ),
            ),
          ),
        );
      },
    );

    test('a dropped connection says so', () async {
      repository.reviewError = _transport(DioExceptionType.connectionError);

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Could not reach the server'),
              contains('connection'),
            ),
          ),
        ),
      );
    });

    test(
      'a timeout says the server was slow, not that the review failed',
      () async {
        repository.reviewError = _transport(DioExceptionType.receiveTimeout);

        await expectLater(
          controller.verify(competencyFixture()),
          throwsA(
            isA<AdminReviewException>().having(
              (error) => error.message,
              'message',
              contains('too long to respond'),
            ),
          ),
        );
      },
    );

    test('a rejected certificate is called a security problem', () async {
      // The one case where "try again" is the wrong advice: retrying against a
      // certificate that was refused is exactly what an attacker would look for.
      repository.reviewError = _transport(DioExceptionType.badCertificate);

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(contains('certificate'), contains('security')),
          ),
        ),
      );
    });

    test(
      'a rejected certificate does not tell the operator to retry',
      () async {
        repository.reviewError = _transport(DioExceptionType.badCertificate);

        await expectLater(
          controller.verify(competencyFixture()),
          throwsA(
            isA<AdminReviewException>().having(
              (error) => error.message,
              'message',
              isNot(contains('Try again')),
            ),
          ),
        );
      },
    );
  });

  group('what never reaches the operator', () {
    test('a URL from the transport is not rendered', () async {
      // A Dio message carries the URL it was trying to reach. The console is
      // internal, so an operator seeing its own host in a snack bar is harmless,
      // but the raw string is not written to be read and can name an internal
      // route the operator has no business being shown.
      repository.reviewError = DioException(
        requestOptions: RequestOptions(
          path: 'https://internal.example/admin/competencies/c1/review',
        ),
      );

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            allOf(
              isNot(contains('internal.example')),
              isNot(contains('10.0.4.7')),
              isNot(contains('5432')),
            ),
          ),
        ),
      );
    });

    test(
      'a non-string field error is dropped rather than rendered as null',
      () async {
        // `retry_after_seconds` is an int in the problem document. Rendering
        // "[object Object]" or "null" beside a validation message helps nobody.
        repository.reviewError = _problem(422, {
          'status': 422,
          'detail': 'Some of the details you entered are not valid.',
          'errors': {
            'status': 'pending is not a review decision',
            'rejection_reason': null,
            'retry_after_seconds': 900,
          },
        });

        await expectLater(
          controller.verify(competencyFixture()),
          throwsA(
            isA<AdminReviewException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('status: pending is not a review decision'),
                isNot(contains('null')),
                isNot(contains('900')),
              ),
            ),
          ),
        );
      },
    );

    test('a 4xx with no problem document still says something specific', () async {
      // A gateway can answer a request without the body's being this API's. The
      // status alone has to produce a usable message.
      repository.reviewError = _problem(409);

      await expectLater(
        controller.verify(competencyFixture()),
        throwsA(
          isA<AdminReviewException>().having(
            (error) => error.message,
            'message',
            contains('conflicts with the current state'),
          ),
        ),
      );
    });

    test(
      'a refusal with no status is not reported as a server fault',
      () async {
        repository.reviewError = DioException(
          requestOptions: RequestOptions(
            path: '/v1/admin/competencies/c1/review',
          ),
          type: DioExceptionType.badResponse,
        );

        await expectLater(
          controller.verify(competencyFixture()),
          throwsA(
            isA<AdminReviewException>().having(
              (error) => error.message,
              'message',
              allOf(
                isNot(contains('sign in')),
                isNot(contains('below the competency threshold')),
              ),
            ),
          ),
        );
      },
    );
  });
}
