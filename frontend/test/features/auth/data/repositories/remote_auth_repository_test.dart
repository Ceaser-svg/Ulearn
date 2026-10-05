import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/storage/token_store.dart';
import 'package:peerpass/features/auth/data/datasources/remote_academics_datasource.dart';
import 'package:peerpass/features/auth/data/datasources/remote_auth_datasource.dart';
import 'package:peerpass/features/auth/data/repositories/remote_auth_repository.dart';

/// A recorded request, so a test can assert on what the client actually sent.
class _Call {
  _Call(this.method, this.path, this.query, this.body);

  final String method;
  final String path;
  final Map<String, dynamic> query;
  final Object? body;

  @override
  String toString() => '$method $path $query $body';
}

/// Answers requests from a script, and records what it was asked.
///
/// A hand-rolled [HttpClientAdapter] rather than a mocking package, because the
/// thing under test *is* the wire: what path was hit, what JSON went out, and what
/// came back. A mock at the datasource boundary would let a wrong URL or a wrong
/// field name pass, which are exactly the bugs this catches.
class _FakeServer implements HttpClientAdapter {
  final List<_Call> calls = [];
  final List<Object?> _replies = [];

  /// Runs as a request is dispatched, before its reply is read.
  ///
  /// Lets a test assert on client state *at the wire*. That is the only place
  /// an ordering bug of this kind is visible: a repository that clears its
  /// tokens one line too early still satisfies a test which only inspects the
  /// state after the call has returned.
  Future<void> Function()? onFetch;

  /// Queues one reply. A [DioException] is thrown instead of returned.
  void reply(int status, Object? body, {Map<String, List<String>>? headers}) {
    _replies.add(_Reply(status, body, headers));
  }

  void fail(DioException error) => _replies.add(error);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await onFetch?.call();
    calls.add(
      _Call(
        options.method,
        options.path,
        options.queryParameters,
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
        ...?r.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Reads back what the caller sent.
///
/// Dio hands an adapter the request body as the caller wrote it, so a `Map` for
/// a JSON request. A pre-encoded string is handled too, because that is what
/// arrives once a transform has run.
Object? _decode(Object? data) {
  if (data is! String) return data;
  try {
    return jsonDecode(data);
  } on FormatException {
    return data;
  }
}

class _Reply {
  _Reply(this.status, this.body, this.headers);

  final int status;
  final Object? body;
  final Map<String, List<String>>? headers;
}

/// A user body shaped like the API's.
Map<String, dynamic> _user({
  String name = 'Achieng Okello',
  String? university = 'university-1',
}) {
  return {
    'id': 'user-1',
    'email': 'student@must.ac.ug',
    'full_name': name,
    'roles': ['student'],
    'university_id': university,
    'faculty_id': 'subject-1',
    'year_of_study': 2,
    'academic_data_consented_at': '2026-01-15T09:00:00Z',
  };
}

Map<String, dynamic> _tokens({
  String access = 'access-1',
  String refresh = 'refresh-1',
  Map<String, dynamic>? user,
}) {
  return {
    'tokens': {
      'access_token': access,
      'refresh_token': refresh,
      'token_type': 'Bearer',
      'expires_in': 900,
    },
    'user': user ?? _user(),
  };
}

void main() {
  late _FakeServer server;
  late InMemoryTokenStore store;
  late RemoteAuthRepository repository;

  setUp(() {
    server = _FakeServer();
    store = InMemoryTokenStore();
    // validateStatus matches the production client, so a 4xx here throws exactly
    // as it would against the real API. A test client that returned error
    // statuses as values would never exercise the failure mapping.
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.peerpass.test',
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    )..httpClientAdapter = server;

    repository = RemoteAuthRepository(
      auth: RemoteAuthDatasource(dio),
      academics: RemoteAcademicsDatasource(dio),
      tokenStore: store,
    );
  });

  group('signing in', () {
    test('posts to the login endpoint and adopts the account', () async {
      server.reply(200, _tokens());

      final profile = await repository.signIn(
        email: 'student@must.ac.ug',
        password: 'a-long-enough-password',
      );

      expect(server.calls.single.method, 'POST');
      expect(server.calls.single.path, '/v1/auth/login');
      expect(server.calls.single.body, {
        'email': 'student@must.ac.ug',
        'password': 'a-long-enough-password',
      });
      expect(profile.email, 'student@must.ac.ug');
      expect(profile.firstName, 'Achieng');
    });

    test('persists both tokens before the caller sees the account', () async {
      server.reply(200, _tokens());

      await repository.signIn(
        email: 'student@must.ac.ug',
        password: 'a-long-enough-password',
      );

      expect(await store.readAccessToken(), 'access-1');
      expect(await store.readRefreshToken(), 'refresh-1');
    });

    test('a rejected password reports what the API said, not a sign-out', () async {
      // The bug this pins: every 401 used to become "your session has ended",
      // which tells a student who mistyped their password that they were logged
      // out and sends them to the sign-in screen they are already on.
      server.reply(401, {
        'type': 'https://peerpass.app/problems/authentication_failed',
        'title': 'Authentication failed',
        'status': 401,
        'detail': 'That email or password is not right.',
      });

      await expectLater(
        repository.signIn(
          email: 'student@must.ac.ug',
          password: 'wrong-but-long-enough',
        ),
        throwsA(
          isA<AuthFailure>().having(
            (f) => f.message,
            'message',
            'That email or password is not right.',
          ),
        ),
      );
    });

    test('a rejected password leaves no token behind', () async {
      server.reply(401, <String, Object?>{
        'status': 401,
        'detail': 'That email or password is not right.',
      });

      await repository
          .signIn(
            email: 'student@must.ac.ug',
            password: 'wrong-but-long-enough',
          )
          .then<void>((_) {}, onError: (Object _) {});

      expect(await store.readRefreshToken(), isNull);
    });
  });

  group('registering', () {
    test(
      'sends only an email and a password, and gets a nameless student',
      () async {
        server.reply(
          201,
          _tokens(
            user: _user(name: 'x', university: null)
              // A brand-new account has no name at all, so the key is absent.
              ..remove('full_name'),
          ),
        );

        final profile = await repository.register(
          email: 'newcomer@must.ac.ug',
          password: 'a-long-enough-password',
        );

        expect(server.calls.single.path, '/v1/auth/register');
        expect(
          server.calls.single.body,
          {
            'email': 'newcomer@must.ac.ug',
            'password': 'a-long-enough-password',
          },
          reason:
              'a full_name or roles key here would be silently ignored by '
              'the API, and would look like the client set a name the student '
              'never gave',
        );
        expect(profile.fullName, isNull);
        expect(profile.needsOnboarding, isTrue);
      },
    );

    test(
      'a duplicate address surfaces the conflict, not a generic error',
      () async {
        server.reply(409, {
          'status': 409,
          'detail': 'An account already exists for that email address.',
        });

        await expectLater(
          repository.register(
            email: 'taken@must.ac.ug',
            password: 'a-long-enough-password',
          ),
          throwsA(isA<ConflictFailure>()),
        );
      },
    );
  });

  group('restoring on a cold start', () {
    test(
      'no stored refresh token means signed out, and no request is made',
      () async {
        // A launch with nothing stored must not spend a round trip asking.
        expect(await repository.restoreSession(), isNull);
        expect(server.calls, isEmpty);
      },
    );

    test('renews the token, then asks who it belongs to', () async {
      await store.write(accessToken: 'stale', refreshToken: 'refresh-1');
      server
        ..reply(200, _tokens(access: 'access-2', refresh: 'refresh-2'))
        ..reply(200, _user());

      final profile = await repository.restoreSession();

      expect(server.calls.map((c) => c.path).toList(), [
        '/v1/auth/refresh',
        '/v1/auth/me',
      ]);
      expect(server.calls.first.body, {'refresh_token': 'refresh-1'});
      expect(profile?.email, 'student@must.ac.ug');
    });

    test(
      'the renewed pair replaces the old one, with no stale refresh left',
      () async {
        await store.write(accessToken: 'stale', refreshToken: 'refresh-1');
        server
          ..reply(200, _tokens(access: 'access-2', refresh: 'refresh-2'))
          ..reply(200, _user());

        await repository.restoreSession();

        expect(await store.readAccessToken(), 'access-2');
        expect(await store.readRefreshToken(), 'refresh-2');
      },
    );

    test('a refresh the server refuses reports signed out and forgets the token', () async {
      // The dead credential has to go. Leaving it means every subsequent launch
      // replays a token the server has already revoked, and the student can
      // never get past splash.
      await store.write(accessToken: 'stale', refreshToken: 'revoked');
      server.reply(401, {
        'status': 401,
        'detail': 'That refresh token is not valid.',
      });

      expect(await repository.restoreSession(), isNull);
      expect(await store.readRefreshToken(), isNull);
    });

    test('a dropped connection is an error, not a silent sign-out', () async {
      // A student in a tunnel still holds a valid session. Reporting signed out
      // here loses their place and looks like the app forgot them.
      await store.write(accessToken: 'stale', refreshToken: 'refresh-1');
      server.fail(
        DioException(
          requestOptions: RequestOptions(path: '/v1/auth/refresh'),
          type: DioExceptionType.connectionError,
        ),
      );

      await expectLater(
        repository.restoreSession(),
        throwsA(isA<NetworkFailure>()),
      );
      expect(
        await store.readRefreshToken(),
        'refresh-1',
        reason: 'a transient network failure is not a revoked token',
      );
    });
  });

  group('refreshing for a retried request', () {
    test(
      'no stored token reports false rather than attempting a call',
      () async {
        expect(await repository.refreshSession(), isFalse);
        expect(server.calls, isEmpty);
      },
    );

    test('a successful refresh swaps the pair in', () async {
      await store.write(accessToken: 'stale', refreshToken: 'refresh-1');
      server.reply(200, _tokens(access: 'access-2', refresh: 'refresh-2'));

      expect(await repository.refreshSession(), isTrue);
      expect(await store.readAccessToken(), 'access-2');
    });

    test(
      'a refused refresh clears the token so nothing retries it forever',
      () async {
        await store.write(accessToken: 'stale', refreshToken: 'revoked');
        server.reply(401, {'status': 401, 'detail': 'nope'});

        expect(await repository.refreshSession(), isFalse);
        expect(await store.readRefreshToken(), isNull);
      },
    );
  });

  group('updating the profile', () {
    test('patches the caller own record and returns the stored one', () async {
      server.reply(200, _user());

      final profile = await repository.updateProfile(
        fullName: 'Achieng Okello',
      );

      expect(server.calls.single.method, 'PATCH');
      expect(server.calls.single.path, '/v1/users/me');
      expect(server.calls.single.body, {'full_name': 'Achieng Okello'});
      expect(profile.fullName, 'Achieng Okello');
    });

    test(
      'sends only the fields supplied, so a step cannot blank a prior one',
      () async {
        // The wizard saves one step at a time. A client that sent nulls for the
        // fields it was not editing would erase the university the student already
        // chose on the previous screen.
        server.reply(200, _user());

        await repository.updateProfile(
          universityId: 'university-1',
          yearOfStudy: 3,
        );

        expect(server.calls.single.body, {
          'university_id': 'university-1',
          'year_of_study': 3,
        });
      },
    );

    test(
      'a rejected field comes back as a validation failure with the reason',
      () async {
        server.reply(422, {
          'status': 422,
          'detail': 'Some of the details you entered are not valid.',
          'errors': {'year_of_study': 'Year of study must be between 1 and 6.'},
        });

        await expectLater(
          repository.updateProfile(yearOfStudy: 9),
          throwsA(
            isA<ValidationFailure>().having(
              (f) => f.fieldErrors['year_of_study'],
              'year_of_study reason',
              'Year of study must be between 1 and 6.',
            ),
          ),
        );
      },
    );

    test(
      'an unreadable body is reported as a server fault, not a silent null',
      () async {
        server.reply(200, {'unexpected': 'shape'});

        await expectLater(
          repository.updateProfile(fullName: 'Achieng'),
          throwsA(isA<ServerFailure>()),
        );
      },
    );
  });

  group('signing out', () {
    test('clears the device token even when the request fails', () async {
      // The user's intent is not conditional on the network, and a sign-out that
      // silently failed would leave a live token on the handset.
      await store.write(accessToken: 'access-1', refreshToken: 'refresh-1');
      server.fail(
        DioException(
          requestOptions: RequestOptions(path: '/v1/auth/logout'),
          type: DioExceptionType.connectionError,
        ),
      );

      await repository.signOut();

      expect(await store.readAccessToken(), isNull);
      expect(await store.readRefreshToken(), isNull);
    });

    test('revokes the token server-side when it can', () async {
      await store.write(accessToken: 'access-1', refreshToken: 'refresh-1');
      server.reply(204, null);

      await repository.signOut();

      expect(server.calls.single.path, '/v1/auth/logout');
      expect(server.calls.single.body, {'refresh_token': 'refresh-1'});
    });
  });

  group('deleting the account', () {
    test('the request goes out while the access token is still held', () async {
      // The bug this pins. The access token *is* the authorisation for this
      // request, so clearing the store before sending leaves the client holding
      // nothing and the API answers 401: the account survives, and the user is
      // signed out of an account they asked to erase.
      await store.write(accessToken: 'access-1', refreshToken: 'refresh-1');
      String? heldAtTheWire;
      server
        ..onFetch = () async {
          heldAtTheWire = await store.readAccessToken();
        }
        ..reply(204, null);

      await repository.deleteAccount();

      expect(heldAtTheWire, 'access-1');
      expect(server.calls.single.method, 'DELETE');
      expect(server.calls.single.path, '/v1/users/me');
    });

    test('clears the tokens once the server has confirmed', () async {
      await store.write(accessToken: 'access-1', refreshToken: 'refresh-1');
      server.reply(204, null);

      await repository.deleteAccount();

      expect(await store.readAccessToken(), isNull);
      expect(await store.readRefreshToken(), isNull);
    });

    test(
      'a refused delete keeps the session, so a retry is still possible',
      () async {
        // What the screen offers when it says "your account is unchanged, try
        // again" has to be true. Signing out on the way past is what turned a
        // failed delete into a dead end.
        await store.write(accessToken: 'access-1', refreshToken: 'refresh-1');
        server.reply(500, {
          'status': 500,
          'detail': 'could not reach the store',
        });

        await expectLater(repository.deleteAccount(), throwsA(isA<Failure>()));

        expect(await store.readAccessToken(), 'access-1');
        expect(await store.readRefreshToken(), 'refresh-1');
      },
    );

    test(
      'an unauthorised delete keeps the tokens rather than signing out',
      () async {
        // The specific failure that was reported. Even when the server refuses,
        // throwing away the credentials leaves the user with no way back in and
        // an account they were told was not deleted.
        await store.write(accessToken: 'access-1', refreshToken: 'refresh-1');
        server.reply(401, {
          'status': 401,
          'detail': 'Could not validate credentials',
        });

        await expectLater(
          repository.deleteAccount(),
          throwsA(isA<AuthFailure>()),
        );

        expect(await store.readAccessToken(), 'access-1');
      },
    );
  });

  group('academic lookups', () {
    test('reads the universities into picker options', () async {
      server.reply(200, [
        {
          'id': 'university-1',
          'name': 'Mbarara University of Science and Technology',
          'grading_scale_id': 'scale-1',
        },
      ]);

      final universities = await repository.universities();

      expect(server.calls.single.path, '/v1/academics/universities');
      expect(universities.single.publicId, 'university-1');
      expect(universities.single.gradingScaleId, 'scale-1');
    });

    test('reads the faculties', () async {
      server.reply(200, [
        {'id': 'subject-1', 'name': 'School of Business and Management'},
      ]);

      final faculties = await repository.faculties(
        universityId: 'university-1',
      );

      expect(server.calls.single.path, '/v1/academics/faculties');
      expect(server.calls.single.query, {'university_id': 'university-1'});
      expect(faculties.single.name, 'School of Business and Management');
    });

    // The grades reply below is the body the API actually sends, decimals
    // included. It is written out literally rather than built from a helper
    // because the bug it guards is a disagreement between two representations
    // of the same field: a fixture that produced `5.0` would have kept the
    // broken cast passing.
    test('reads the grades whose points arrive as JSON strings', () async {
      server.reply(200, [
        {
          'id': 'grade-a',
          'label': 'A',
          'grade_points': '5.00',
          'max_points': '5.00',
          'grading_scale_id': 'scale-1',
        },
        {
          'id': 'grade-b-plus',
          'label': 'B+',
          'grade_points': '4.50',
          'max_points': '5.00',
          'grading_scale_id': 'scale-1',
        },
      ]);

      final grades = await repository.grades(universityId: 'university-1');

      expect(server.calls.single.path, '/v1/academics/grades');
      expect(server.calls.single.query, {'university_id': 'university-1'});
      expect(grades.map((grade) => grade.publicId), [
        'grade-a',
        'grade-b-plus',
      ]);
      expect(grades.first.label, 'A');
      expect(grades.first.gradePoints, 5.0);
      expect(grades.last.gradePoints, 4.5);
    });

    test('still reads grades sent as JSON numbers', () async {
      server.reply(200, [
        {'id': 'grade-a', 'label': 'A', 'grade_points': 5.0},
      ]);

      final grades = await repository.grades(universityId: 'university-1');

      expect(grades.single.gradePoints, 5.0);
    });

    test('reports an unreadable grade body as a server fault', () async {
      server.reply(200, [
        {'id': 'grade-a', 'label': 'A'},
      ]);

      await expectLater(
        repository.grades(universityId: 'university-1'),
        throwsA(
          isA<ServerFailure>().having(
            (failure) => failure.message,
            'message',
            'The server sent something we could not read.',
          ),
        ),
      );
    });

    test('reads the course units for a faculty', () async {
      server.reply(200, [
        {
          'id': 'unit-1',
          'code': 'BIT 221',
          'name': 'Operating Systems',
          'description': null,
          'university_id': 'university-1',
          'subject_id': 'subject-1',
          'grade_id': null,
        },
      ]);

      final units = await repository.courseUnits(
        universityId: 'university-1',
        subjectId: 'subject-1',
      );

      expect(server.calls.single.path, '/v1/academics/course-units');
      expect(server.calls.single.query, {
        'university_id': 'university-1',
        'subject_id': 'subject-1',
      });
      expect(units.single.code, 'BIT 221');
      expect(units.single.name, 'Operating Systems');
    });
  });
}
