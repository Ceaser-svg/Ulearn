import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/competencies/data/datasources/remote_competencies_datasource.dart';
import 'package:peerpass/features/competencies/data/models/tutor_claim.dart';
import 'package:peerpass/features/competencies/data/repositories/remote_competencies_repository.dart';

/// A recorded request, so a test can assert on what the client actually sent.
class _Call {
  _Call(this.method, this.path, this.data);

  final String method;
  final String path;

  /// The request body as Dio was handed it: the decoded object, not the encoded
  /// form, because that is what a client actually built.
  final Object? data;

  @override
  String toString() => '$method $path';
}

/// Answers requests from a script, and records what it was asked.
///
/// The same shape as the sessions, tutors and incentives repository tests: what
/// is under test here is the wire -- which path, which method, what the client
/// sends, and what happens to each kind of bad answer. A mock at the datasource
/// boundary would let a renamed route pass.
class _FakeServer implements HttpClientAdapter {
  final List<_Call> calls = [];
  final List<Object?> _replies = [];

  void reply(int status, Object? body) => _replies.add(_Reply(status, body));

  /// Sends text verbatim, so a test can answer with something that is not JSON at
  /// all -- a proxy's error page, or a gateway that gives up in plain text.
  void replyRaw(int status, String text) => _replies.add(_Raw(status, text));

  void fail(DioException error) => _replies.add(error);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(_Call(options.method, options.path, options.data));

    final reply = _replies.removeAt(0);
    if (reply is DioException) throw reply;

    if (reply is _Raw) {
      return ResponseBody.fromString(
        reply.text,
        reply.status,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }

    final r = reply! as _Reply;
    return ResponseBody.fromString(
      r.body == null ? '' : jsonEncode(r.body),
      r.status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Reply {
  _Reply(this.status, this.body);

  final int status;
  final Object? body;
}

class _Raw {
  _Raw(this.status, this.text);

  final int status;
  final String text;
}

Map<String, dynamic> _claim({
  String id = 'claim-1',
  String status = 'pending',
  String? rejectionReason,
}) {
  return {
    'id': id,
    'user_id': 'student-1',
    'course_unit_id': 'unit-1',
    'course_unit_code': 'MAT 221',
    'course_unit_name': 'Linear Algebra',
    'grade_id': 'grade-1',
    'grade_label': 'A',
    'status': status,
    'source': 'transcript',
    // A string, as the API serialises a `numeric(6,2)`.
    'grade_points': '5.00',
    'meets_threshold': status == 'verified',
    'verified_at': status == 'verified' ? '2026-03-02T09:00:00Z' : null,
    'rejection_reason': rejectionReason,
    'evidence_reference': 'Semester 5 transcript',
    'created_at': '2026-03-01T08:00:00Z',
  };
}

/// The API's own refusal, in the problem details shape it uses everywhere.
Map<String, dynamic> _problem({
  int status = 409,
  String title = 'Conflict',
  String detail = 'A competency already exists for this unit.',
}) {
  return {
    'type': 'https://peerpass.app/problems/conflict',
    'title': title,
    'status': status,
    'detail': detail,
  };
}

void main() {
  late _FakeServer server;
  late RemoteCompetenciesRepository repository;

  setUp(() {
    server = _FakeServer();
    // `validateStatus` matches the production client, so a 4xx throws here exactly
    // as it would against the real API. A test client that returned error statuses
    // as values would never exercise the failure mapping.
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.peerpass.test',
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    )..httpClientAdapter = server;

    repository = RemoteCompetenciesRepository(
      datasource: RemoteCompetenciesDatasource(dio),
    );
  });

  group('myClaims', () {
    test("asks for the caller's own claims, with nothing naming them", () async {
      // No user id in the path and no query: these are the caller's own claims, so
      // a test that saw a parameter here would be seeing a client that could be
      // asked about somebody else. This is the scope that matters most in the
      // feature, because a claim is academic data about a specific student.
      server.reply(200, [_claim()]);

      await repository.myClaims();

      expect(server.calls.single.method, 'GET');
      expect(server.calls.single.path, '/v1/competencies/me');
    });

    test('reads a rejected claim with the reason attached', () async {
      // The reason is the only thing that makes a refusal actionable, so the
      // client has to carry it through rather than showing a status alone.
      server.reply(200, [
        _claim(
          status: 'rejected',
          rejectionReason: 'The transcript reference does not name the course.',
        ),
      ]);

      final claims = await repository.myClaims();

      expect(claims.single.status, TutorClaimStatus.rejected);
      expect(
        claims.single.rejectionReason,
        'The transcript reference does not name the course.',
      );
    });

    test('an empty list is an empty list, not a failure', () async {
      // A student who has never applied is in this state on purpose, and the
      // screen offers the form rather than reporting an error.
      server.reply(200, <Map<String, dynamic>>[]);

      expect(await repository.myClaims(), isEmpty);
    });

    test('a body that is not a list is named as an unreadable body', () async {
      // Answering with an object rather than a list must not become an empty
      // claims list -- that would tell a tutor they have never applied when the
      // API in fact said something else -- and must not reach the screen as a
      // cast error either.
      server.reply(200, <String, dynamic>{'claims': <Object?>[]});

      expect(
        repository.myClaims,
        throwsA(
          isA<ServerFailure>().having(
            (failure) => failure.message,
            'message',
            contains('could not read'),
          ),
        ),
      );
    });

    test('an empty body is named rather than read as no claims', () async {
      // Null is what a 204 or an empty response gives. "No claims" and "no body"
      // are different claims about the server, and only one of them is the
      // screen's empty state.
      server.reply(200, null);

      expect(repository.myClaims, throwsA(isA<ServerFailure>()));
    });

    test(
      'an expired token becomes an auth failure the screen can act on',
      () async {
        server.reply(401, _problem(status: 401, detail: 'Not authenticated.'));

        expect(repository.myClaims, throwsA(isA<AuthFailure>()));
      },
    );

    test('a problem document is reported by its detail, not its title', () async {
      // The detail is written for the person who made the request; the title is
      // a category name. The exception text is never shown raw.
      server.reply(409, _problem());

      expect(
        repository.myClaims,
        throwsA(
          isA<ConflictFailure>().having(
            (failure) => failure.message,
            'message',
            'A competency already exists for this unit.',
          ),
        ),
      );
    });

    test('a lost connection is a network failure', () async {
      server.fail(
        DioException(
          requestOptions: RequestOptions(path: '/v1/competencies/me'),
          type: DioExceptionType.connectionError,
          error: 'connection refused',
        ),
      );

      expect(repository.myClaims, throwsA(isA<NetworkFailure>()));
    });

    test('a gateway that answers in plain text does not reach the screen', () async {
      // Not JSON at all. Whatever the client does with it, it must arrive as a
      // Failure; the raw text of an HTML error page has no business in the UI.
      server.replyRaw(502, '<html><body>Bad Gateway</body></html>');

      expect(
        repository.myClaims,
        throwsA(
          isA<Failure>().having(
            (failure) => failure.message,
            'message',
            isNot(contains('Bad Gateway')),
          ),
        ),
      );
    });

    test('a 5xx is a server fault, not an unknown one', () async {
      server.reply(500, _problem(status: 500, title: 'Internal Server Error'));

      expect(repository.myClaims, throwsA(isA<ServerFailure>()));
    });
  });

  group('submitClaim', () {
    test('posts to the collection and returns the stored claim', () async {
      // The response body is used rather than a locally-built pending claim, so a
      // screen that has just submitted shows the state the API actually recorded.
      server.reply(201, _claim());

      final created = await repository.submitClaim(
        courseUnitId: 'unit-1',
        gradeId: 'grade-1',
        source: 'transcript',
        evidenceReference: 'Semester 5 transcript',
      );

      expect(server.calls.single.method, 'POST');
      expect(server.calls.single.path, '/v1/competencies');
      expect(created.status, TutorClaimStatus.pending);
      expect(created.courseUnitCode, 'MAT 221');
    });

    test('sends the fields the API documents, omitting absent ones', () async {
      server.reply(201, _claim());

      await repository.submitClaim(
        courseUnitId: 'unit-1',
        gradeId: 'grade-1',
        source: 'transcript',
      );

      final sent = server.calls.single.data! as Map<String, dynamic>;
      expect(sent['course_unit_id'], 'unit-1');
      expect(sent['grade_id'], 'grade-1');
      expect(sent['source'], 'transcript');
      // Sent as null rather than omitted: the API's model makes both optional, and
      // a null is what a not-yet-typed evidence reference actually is. What must
      // not happen is an empty string being smuggled in as a value, which the
      // API would store as a claim that a tutor claimed no evidence.
      expect(sent.containsKey('evidence_reference'), isTrue);
      expect(sent['evidence_reference'], isNull);
      expect(sent.containsKey('notes'), isTrue);
      expect(sent['notes'], isNull);
    });

    test('a validation refusal keeps its field errors', () async {
      // The submission form needs to know *which* field the API rejected; a
      // failure that dropped them would force the tutor to guess.
      server.reply(422, {
        'title': 'Validation failed',
        'status': 422,
        'detail': 'Some of the details you entered are not valid.',
        // A map, which is what `ValidationProblem` puts in `errors`: keyed by
        // the field name so a form can render the message beside the input.
        'errors': {
          'course_unit_id': 'A competency already exists for this unit.',
        },
      });

      expect(
        repository.submitClaim(
          courseUnitId: 'unit-1',
          gradeId: 'grade-1',
          source: 'transcript',
        ),
        throwsA(
          isA<ValidationFailure>().having(
            (failure) => failure.fieldErrors,
            'fieldErrors',
            containsPair('course_unit_id', contains('already exists')),
          ),
        ),
      );
    });
  });
}
