import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/matching/data/datasources/remote_matching_datasource.dart';
import 'package:peerpass/features/matching/data/models/help_request.dart';
import 'package:peerpass/features/matching/data/repositories/remote_matching_repository.dart';

/// A recorded request, so a test can assert on what the client actually sent.
class _Call {
  _Call(this.method, this.path, this.query, this.body);

  final String method;
  final String path;
  final Map<String, dynamic> query;
  final Object? body;

  @override
  String toString() => '$method $path?$query $body';
}

/// Answers requests from a script, and records what it was asked.
///
/// Copied in shape from the sessions repository test: the thing under test is the
/// wire -- which route, which body, which query -- and a mock at the datasource
/// boundary would let a renamed field pass.
class _FakeServer implements HttpClientAdapter {
  final List<_Call> calls = [];
  final List<Object?> _replies = [];

  void reply(int status, Object? body) => _replies.add(_Reply(status, body));

  void fail(DioException error) => _replies.add(error);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(
      _Call(
        options.method,
        options.path,
        options.queryParameters.map(
          (key, value) => MapEntry(key, value as Object),
        ),
        _decode(options.data),
      ),
    );

    final reply = _replies.removeAt(0);
    if (reply is DioException) throw reply;

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

Object? _decode(Object? data) {
  if (data is! String) return data;
  try {
    return jsonDecode(data);
  } on FormatException {
    return data;
  }
}

class _Reply {
  _Reply(this.status, this.body);

  final int status;
  final Object? body;
}

Map<String, dynamic> _matchResponse({
  List<Map<String, dynamic>> candidates = const [],
  List<Map<String, dynamic>> exclusions = const [],
  bool? widened,
  bool? none,
}) {
  return {
    'course_unit_id': 'unit-1',
    'request_id': null,
    'generated_at': '2026-03-04T09:12:00Z',
    'widened': ?widened,
    'no_eligible_tutors': ?none,
    'candidates': candidates,
    'exclusions': exclusions,
  };
}

Map<String, dynamic> _tutor({String id = 'tutor-1'}) {
  return {
    'user_id': id,
    'full_name': 'Grace Okello',
    'standing': 'verified',
    'average_rating': '4.10',
    'completed_sessions': 12,
  };
}

Map<String, dynamic> _candidate({String id = 'tutor-1'}) {
  return {
    'tutor': _tutor(id: id),
    'course_unit_id': 'unit-1',
    'competency_grade_points': '82.50',
    'meets_threshold': true,
    'score': 0.93,
  };
}

/// `HelpRequestResponse`, with the optional fields left out unless asked for.
Map<String, dynamic> _helpResponse({
  String status = 'open',
  String? matchedTutorId,
}) {
  return {
    'id': 'request-1',
    'tutee_id': 'student-1',
    'course_unit_id': 'unit-1',
    'topic': 'eigenvalues',
    'description': null,
    'status': status,
    'matched_tutor_id': matchedTutorId,
    'created_at': '2026-03-04T09:12:00Z',
  };
}

/// The API's own refusal, as `MatchRequest` validation produces it.
Map<String, dynamic> _problem({
  int status = 422,
  String title = 'Validation failed',
  String detail = 'course_unit_id is required.',
  Map<String, String>? errors,
}) {
  return {
    'type': 'https://peerpass.app/problems/validation',
    'title': title,
    'status': status,
    'detail': detail,
    'errors': ?errors,
  };
}

void main() {
  late _FakeServer server;
  late RemoteMatchingRepository repository;

  setUp(() {
    server = _FakeServer();
    // validateStatus matches the production client, so a 4xx throws here exactly
    // as it would against the real API. A test client that returned error statuses
    // as values would never exercise the failure mapping.
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.peerpass.test',
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    )..httpClientAdapter = server;
    repository = RemoteMatchingRepository(RemoteMatchingDatasource(dio));
  });

  group('asking who may take a course unit', () {
    test('posts the three documented fields, and nothing else', () async {
      server.reply(200, _matchResponse(candidates: [_candidate()]));

      await repository.suggestions(courseUnitId: 'unit-1');

      // `MatchRequest` forbids unknown keys, so this is also the test that would
      // fail loudly if a client grew a field the API rejects with a 422. The unit
      // route is the one this client calls: `/help-requests/{id}/matches` answers
      // about a request the caller owns, which this client does not send.
      final call = server.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/matching/suggestions');
      expect(call.body, {
        'course_unit_id': 'unit-1',
        'widen_to_subject': false,
      });
    });

    test('does not widen unless the caller asked', () async {
      server.reply(200, _matchResponse());

      await repository.suggestions(courseUnitId: 'unit-1');

      final body = server.calls.single.body! as Map<String, dynamic>;
      // Off by default, because the API's default is off and widening by
      // default would return tutors who cannot help with the course asked about.
      expect(body['widen_to_subject'], isFalse);
    });

    test('sends the widening flag the caller set', () async {
      server.reply(200, _matchResponse(widened: true, none: true));

      final result = await repository.suggestions(
        courseUnitId: 'unit-1',
        widenToSubject: true,
      );

      final body = server.calls.single.body! as Map<String, dynamic>;
      expect(body['widen_to_subject'], isTrue);
      // And the flag in the response is what the caller is told about: this is the
      // field a screen has to render, not the one it asked with.
      expect(result.widened, isTrue);
    });

    test('leaves limit out rather than inventing a rail length', () async {
      server.reply(200, _matchResponse());

      await repository.suggestions(courseUnitId: 'unit-1');

      final body = server.calls.single.body! as Map<String, dynamic>;
      // The API's own bound stays the client's bound, so a server-side change
      // does not leave the app asking for a different number of tutors than it
      // used to.
      expect(body.containsKey('limit'), isFalse);
    });

    test('sends a limit the caller asked for', () async {
      server.reply(200, _matchResponse());

      await repository.suggestions(courseUnitId: 'unit-1', limit: 3);

      final body = server.calls.single.body! as Map<String, dynamic>;
      expect(body['limit'], 3);
    });

    test('nobody being eligible arrives as a result, not a failure', () async {
      server.reply(
        200,
        _matchResponse(
          widened: true,
          none: true,
          exclusions: [
            {'tutor_id': 'tutor-9', 'reason': 'below_threshold'},
          ],
        ),
      );

      final result = await repository.suggestions(
        courseUnitId: 'unit-1',
        widenToSubject: true,
      );

      expect(result.noEligibleTutors, isTrue);
      expect(result.candidates, isEmpty);
      expect(result.exclusions.single.explanation, isNotEmpty);
    });

    test('the score is read and kept off the screen', () async {
      // Asserted in a repository test because this is where the wire shape is
      // known: `score` is a JSON number, unlike the Decimal fields beside it.
      server.reply(200, _matchResponse(candidates: [_candidate()]));

      final result = await repository.suggestions(courseUnitId: 'unit-1');

      expect(result.candidates.single.score, 0.93);
      expect(result.candidates.single.competencyGradePoints, 82.5);
    });

    test('a refused body is a ValidationFailure naming the field', () async {
      server.reply(
        422,
        _problem(errors: {'course_unit_id': 'Field required.'}),
      );

      await expectLater(
        repository.suggestions(courseUnitId: 'unit-1'),
        throwsA(
          isA<ValidationFailure>().having(
            (failure) => failure.fieldErrors,
            'fieldErrors',
            containsPair('course_unit_id', 'Field required.'),
          ),
        ),
      );
    });

    test('a body of the wrong shape is a ServerFailure, not a crash', () async {
      // The parse runs inside the repository's guard, so an unreadable response
      // reaches a screen as a message instead of a `FormatException` type name.
      server.reply(200, {'candidates': 'not a list'});

      await expectLater(
        repository.suggestions(courseUnitId: 'unit-1'),
        throwsA(isA<ServerFailure>()),
      );
    });
  });

  group('the course unit catalogue', () {
    test('is read as the bare array the endpoint returns', () async {
      server.reply(200, [
        {'id': 'unit-1', 'code': 'MAT 221', 'name': 'Linear Algebra II'},
        {'id': 'unit-2', 'code': 'PHY 105', 'name': 'Mechanics'},
      ]);

      final units = await repository.courseUnits();

      expect(units.map((unit) => unit.code), ['MAT 221', 'PHY 105']);
      expect(units.first.publicId, 'unit-1');
      expect(units.first.name, 'Linear Algebra II');
      expect(server.calls.single.path, '/v1/academics/course-units');
      // No university of its own: the session's is the one that counts, and the
      // API already scopes the answer to the caller.
      expect(server.calls.single.query, isEmpty);
    });

    test('sends a university when the caller has one to name', () async {
      server.reply(200, const []);

      await repository.courseUnits(universityId: 'university-1');

      expect(server.calls.single.query, {'university_id': 'university-1'});
    });

    test('sends university and faculty scope together', () async {
      server.reply(200, const []);

      await repository.courseUnits(
        universityId: 'university-1',
        subjectId: 'faculty-1',
      );

      expect(server.calls.single.query, {
        'university_id': 'university-1',
        'subject_id': 'faculty-1',
      });
    });

    test('an empty catalogue is a list, not a failure', () async {
      server.reply(200, const []);

      expect(await repository.courseUnits(), isEmpty);
    });

    test('a dropped connection is a NetworkFailure', () async {
      server.fail(
        DioException(
          requestOptions: RequestOptions(path: '/v1/academics/course-units'),
          type: DioExceptionType.connectionError,
          error: 'connection refused',
        ),
      );

      await expectLater(
        repository.courseUnits(),
        throwsA(isA<NetworkFailure>()),
      );
    });
  });

  group('asking a tutor to take a request', () {
    test('posts the unit and the topic, and nothing else', () async {
      server.reply(201, _helpResponse());

      await repository.createHelpRequest(
        courseUnitId: 'unit-1',
        topic: 'eigenvalues',
      );

      final call = server.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/matching/help-requests');
      // `HelpRequestCreate` forbids unknown keys, so this is also the test that
      // would fail if the client grew a field the API rejects. The description is
      // absent rather than null: sending one would assert the student wrote
      // nothing, rather than that they had no chance to.
      expect(call.body, {'course_unit_id': 'unit-1', 'topic': 'eigenvalues'});
    });

    test('sends a description the student gave', () async {
      server.reply(201, _helpResponse());

      await repository.createHelpRequest(
        courseUnitId: 'unit-1',
        topic: 'eigenvalues',
        description: 'Stuck on the second eigenvector.',
      );

      expect(
        (server.calls.single.body! as Map<String, dynamic>)['description'],
        'Stuck on the second eigenvector.',
      );
    });

    test(
      'leaves an empty description out rather than sending a blank',
      () async {
        server.reply(201, _helpResponse());

        await repository.createHelpRequest(
          courseUnitId: 'unit-1',
          topic: 'eigenvalues',
          description: '',
        );

        // Absent, not null and not blank. Only the *empty* string is dropped here:
        // trimming belongs to the form that collected it, and a datasource that
        // silently discarded whitespace would hide a caller that forgot to.
        expect(
          (server.calls.single.body! as Map<String, dynamic>).containsKey(
            'description',
          ),
          isFalse,
        );
      },
    );

    test('naming a tutor sends candidate_tutor_id and returns the new state', () async {
      server.reply(
        200,
        _helpResponse(
          status: 'pending_confirmation',
          matchedTutorId: 'tutor-1',
        ),
      );

      final request = await repository.selectTutor(
        requestId: 'request-1',
        candidateTutorId: 'tutor-1',
      );

      final call = server.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/matching/help-requests/request-1/select');
      // Not `tutor_id`: that spelling is refused by `RequestSchema`, which reads a
      // plainly-named user id in a body as a primary key that leaked onto the
      // wire. A test that asserted the shorter name would pass locally and 422 in
      // production.
      expect(call.body, {'candidate_tutor_id': 'tutor-1'});
      // And the answer is a request waiting on a tutor, not a booking. A client
      // that could not see the difference here would say "booked" on the strength
      // of a 200.
      expect(request.status, HelpRequestStatus.pendingConfirmation);
      expect(request.isAwaitingTutor, isTrue);
      expect(request.matchedTutorId, 'tutor-1');
    });

    test(
      'a refusal of the named tutor is a ValidationFailure naming it',
      () async {
        // The API re-derives the candidates for the request's own unit and refuses
        // a tutor who is not among them, however confidently the client names them.
        // This is the path a stale list takes a student down, and the field error is
        // what lets the screen put it next to the row they tapped.
        server.reply(
          422,
          _problem(
            detail: 'That tutor cannot be chosen for this help request.',
            errors: {
              'candidate_tutor_id':
                  'not an eligible tutor for this course unit',
            },
          ),
        );

        await expectLater(
          repository.selectTutor(
            requestId: 'request-1',
            candidateTutorId: 'tutor-9',
          ),
          throwsA(
            isA<ValidationFailure>().having(
              (failure) => failure.fieldErrors,
              'fieldErrors',
              containsPair('candidate_tutor_id', isNotEmpty),
            ),
          ),
        );
      },
    );

    test('asking twice is a ConflictFailure, not a second tutor', () async {
      server.reply(409, _problem(status: 409, title: 'Conflict'));

      await expectLater(
        repository.selectTutor(
          requestId: 'request-1',
          candidateTutorId: 'tutor-2',
        ),
        throwsA(isA<ConflictFailure>()),
      );
    });

    test(
      'an ended session is an AuthFailure, so a screen can send them back',
      () async {
        server.reply(401, _problem(status: 401, title: 'Unauthenticated'));

        await expectLater(
          repository.selectTutor(
            requestId: 'request-1',
            candidateTutorId: 'tutor-1',
          ),
          throwsA(isA<AuthFailure>()),
        );
      },
    );

    test('the student can read what became of their own request', () async {
      server.reply(200, [_helpResponse(status: 'declined')]);

      final mine = await repository.myHelpRequests();

      expect(server.calls.single.path, '/v1/matching/help-requests/me');
      // The only source a student has for "they declined". A screen that cannot
      // read this keeps saying "not yet confirmed" after the API recorded a
      // refusal, which is the one sentence here that can become false on its own.
      expect(mine.single.isDeclined, isTrue);
    });
  });

  group('answering a request that named this tutor', () {
    test('reads the awaiting list from the literal path', () async {
      server.reply(200, [
        _helpResponse(
          status: 'pending_confirmation',
          matchedTutorId: 'tutor-1',
        ),
      ]);

      final awaiting = await repository.requestsAwaitingMe();

      // The literal segment, not `help-requests/{id}`. FastAPI matches in
      // declaration order, so this path being reachable at all is a property of
      // the route table and not something the client controls -- asserting the
      // exact string is what notices the API moving it.
      expect(server.calls.single.method, 'GET');
      expect(
        server.calls.single.path,
        '/v1/matching/help-requests/awaiting-me',
      );
      expect(awaiting.single.isAwaitingTutor, isTrue);
    });

    test('an empty list is a list, not a failure', () async {
      // For a tutor nobody has chosen yet this is the ordinary answer, and it
      // must not put a permission error on a screen that simply has nothing.
      server.reply(200, const []);

      expect(await repository.requestsAwaitingMe(), isEmpty);
    });

    test('turning a request down sends no body and records the refusal', () async {
      server.reply(
        200,
        _helpResponse(status: 'declined', matchedTutorId: 'tutor-1'),
      );

      final declined = await repository.declineHelpRequest(
        requestId: 'request-1',
      );

      final call = server.calls.single;
      expect(call.method, 'POST');
      expect(call.path, '/v1/matching/help-requests/request-1/decline');
      // No body: the decision is entirely the tutor's, so there is nothing for
      // them to say beyond making it.
      expect(call.body, isNull);
      // The tutor is kept on a declined request, because a student cannot
      // reconstruct who turned them down from a status word.
      expect(declined.status, HelpRequestStatus.declined);
      expect(declined.matchedTutorId, 'tutor-1');
    });

    test("someone else's request is a NotFoundFailure", () async {
      // Not a 403: "it exists but is not yours" is an answer, and the API gives
      // the same one as for an id that was never issued.
      server.reply(404, _problem(status: 404, title: 'Not found'));

      await expectLater(
        repository.declineHelpRequest(requestId: 'request-9'),
        throwsA(isA<NotFoundFailure>()),
      );
    });

    test('a second refusal of one request is a ConflictFailure', () async {
      // Declined is terminal. A tutor whose first tap landed and whose second did
      // not get an answer must be told so, rather than seeing a spinner or a
      // request that appears to go back to waiting.
      server.reply(409, _problem(status: 409, title: 'Conflict'));

      await expectLater(
        repository.declineHelpRequest(requestId: 'request-1'),
        throwsA(isA<ConflictFailure>()),
      );
    });

    test(
      'an unreadable row in the list is a ServerFailure, not a crash',
      () async {
        // One bad row must not take the whole list down as a bare `FormatException`
        // on a tutor's screen.
        server.reply(200, [_helpResponse()..remove('topic')]);

        await expectLater(
          repository.requestsAwaitingMe(),
          throwsA(isA<ServerFailure>()),
        );
      },
    );
  });
}
