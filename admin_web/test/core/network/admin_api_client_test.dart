import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/network/admin_api_client.dart';

import '../../support/fake_admin_transport.dart';
import '../../support/fixtures.dart';

AdminApiClient _client(FakeAdminTransport transport) => AdminApiClient(
  baseUrl: 'https://admin.peerpass.test',
  dio: Dio(BaseOptions(baseUrl: 'https://admin.peerpass.test'))
    ..httpClientAdapter = transport,
);

/// Signs in and hands the transport the credentials a validated sign-in would.
///
/// The two steps are separate in the transport on purpose, so that an account
/// refused for lacking the admin role never leaves tokens behind.
Future<void> _signIn(AdminApiClient client) async {
  await client.signIn('operator@peerpass.test', 'a-password');
  client.adoptSession(
    const AdminSession(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      email: 'operator@peerpass.test',
    ),
  );
}

void main() {
  group('paging requests', () {
    test('sends the offset and limit it was asked for', () async {
      final transport = FakeAdminTransport(
        (options) async => jsonResponse(pageJson(items: [], total: 0)),
      );
      final client = _client(transport);

      await client.getPage('/v1/admin/users', offset: 50, limit: 25);

      expect(transport.requests.single.queryParameters, <String, dynamic>{
        'offset': 50,
        'limit': 25,
      });
    });
  });

  group('authorisation', () {
    test('sends the bearer token it holds', () async {
      final transport = FakeAdminTransport(
        (options) async => jsonResponse(loginJson()),
      );
      final client = _client(transport);
      await _signIn(client);

      await client.getPage('/v1/admin/users', offset: 0, limit: 50);

      expect(
        transport.requests.last.headers['Authorization'],
        'Bearer access-token',
      );
    });

    test('refreshes once and retries with the new token on a 401', () async {
      var userCalls = 0;
      final transport = FakeAdminTransport((options) async {
        if (options.path == '/v1/admin/users') {
          userCalls++;
          return userCalls == 1
              ? jsonResponse(<String, dynamic>{
                  'detail': 'expired',
                }, statusCode: 401)
              : jsonResponse(pageJson(items: [], total: 0));
        }
        return jsonResponse(
          loginJson(
            accessToken: 'second-access',
            refreshToken: 'second-refresh',
          ),
        );
      });
      final client = _client(transport);
      await _signIn(client);

      await client.getPage('/v1/admin/users', offset: 0, limit: 50);

      expect(transport.paths, <String>[
        '/v1/auth/login',
        '/v1/admin/users',
        '/v1/auth/refresh',
        '/v1/admin/users',
      ]);
      expect(
        transport.requests.last.headers['Authorization'],
        'Bearer second-access',
      );
    });

    test('refreshes once for a burst of rejections', () async {
      var userCalls = 0;
      final transport = FakeAdminTransport((options) async {
        if (options.path == '/v1/admin/users') {
          userCalls++;
          return userCalls <= 2
              ? jsonResponse(<String, dynamic>{
                  'detail': 'expired',
                }, statusCode: 401)
              : jsonResponse(pageJson(items: [], total: 0));
        }
        return jsonResponse(loginJson(accessToken: 'second-access'));
      });
      final client = _client(transport);
      await _signIn(client);

      await Future.wait(<Future<void>>[
        client.getPage('/v1/admin/users', offset: 0, limit: 50),
        client.getPage('/v1/admin/users', offset: 50, limit: 50),
      ]);

      expect(
        transport.paths.where((path) => path == '/v1/auth/refresh'),
        hasLength(1),
      );
    });

    test('does not retry when the retry is rejected again', () async {
      final transport = FakeAdminTransport((options) async {
        if (options.path == '/v1/auth/login') return jsonResponse(loginJson());
        if (options.path == '/v1/auth/refresh') {
          return jsonResponse(loginJson(accessToken: 'second-access'));
        }
        return jsonResponse(<String, dynamic>{
          'detail': 'nope',
        }, statusCode: 401);
      });
      final client = _client(transport);
      await _signIn(client);

      await expectLater(
        client.getPage('/v1/admin/users', offset: 0, limit: 50),
        throwsA(isA<DioException>()),
      );
      expect(
        transport.paths.where((path) => path == '/v1/admin/users'),
        hasLength(2),
      );
    });
  });

  group('expiry', () {
    test('reports once when the refresh is rejected', () async {
      var reported = 0;
      final transport = FakeAdminTransport((options) async {
        if (options.path == '/v1/auth/login') return jsonResponse(loginJson());
        return jsonResponse(<String, dynamic>{
          'detail': 'expired',
        }, statusCode: 401);
      });
      final client = AdminApiClient(
        baseUrl: 'https://admin.peerpass.test',
        dio: Dio(BaseOptions(baseUrl: 'https://admin.peerpass.test'))
          ..httpClientAdapter = transport,
        onSessionExpired: () => reported++,
      );
      await _signIn(client);

      await expectLater(
        client.getPage('/v1/admin/users', offset: 0, limit: 50),
        throwsA(isA<DioException>()),
      );

      expect(reported, 1);
    });

    test(
      'reports when a refresh is impossible because there is no token',
      () async {
        var reported = 0;
        final transport = FakeAdminTransport(
          (options) async => jsonResponse(<String, dynamic>{
            'detail': 'expired',
          }, statusCode: 401),
        );
        final client = AdminApiClient(
          baseUrl: 'https://admin.peerpass.test',
          dio: Dio(BaseOptions(baseUrl: 'https://admin.peerpass.test'))
            ..httpClientAdapter = transport,
          onSessionExpired: () => reported++,
        );

        await expectLater(
          client.getPage('/v1/admin/users', offset: 0, limit: 50),
          throwsA(isA<DioException>()),
        );

        expect(reported, 1);
        expect(transport.paths, <String>['/v1/admin/users']);
      },
    );

    test('reports when the refresh returns an unusable token', () async {
      var reported = 0;
      final transport = FakeAdminTransport((options) async {
        if (options.path == '/v1/auth/login') return jsonResponse(loginJson());
        if (options.path == '/v1/auth/refresh') {
          return jsonResponse(<String, dynamic>{
            'tokens': <String, dynamic>{'access_token': 7},
          });
        }
        return jsonResponse(<String, dynamic>{
          'detail': 'expired',
        }, statusCode: 401);
      });
      final client = AdminApiClient(
        baseUrl: 'https://admin.peerpass.test',
        dio: Dio(BaseOptions(baseUrl: 'https://admin.peerpass.test'))
          ..httpClientAdapter = transport,
        onSessionExpired: () => reported++,
      );
      await _signIn(client);

      await expectLater(
        client.getPage('/v1/admin/users', offset: 0, limit: 50),
        throwsA(isA<DioException>()),
      );

      expect(reported, 1);
    });

    test('signing out reports and drops the bearer token', () async {
      var reported = 0;
      final transport = FakeAdminTransport(
        (options) async => jsonResponse(pageJson(items: [], total: 0)),
      );
      final client = AdminApiClient(
        baseUrl: 'https://admin.peerpass.test',
        dio: Dio(BaseOptions(baseUrl: 'https://admin.peerpass.test'))
          ..httpClientAdapter = transport,
        onSessionExpired: () => reported++,
      );
      await _signIn(client);

      client.signOut();
      await client.getPage('/v1/admin/users', offset: 0, limit: 50);

      expect(reported, 1);
      expect(transport.requests.last.headers['Authorization'], 'Bearer null');
    });
  });
}
