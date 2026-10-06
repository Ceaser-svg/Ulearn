import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_page.dart';
import 'package:peerpass_admin/core/models/competency_status.dart';
import 'package:peerpass_admin/core/network/admin_api_client.dart';
import 'package:peerpass_admin/features/admin/data/repositories/admin_repository.dart';
import 'package:peerpass_admin/features/admin/data/repositories/http_admin_repository.dart';

import '../../../../support/fake_admin_transport.dart';
import '../../../../support/fixtures.dart';

void main() {
  late FakeAdminTransport transport;

  /// Answers every path: a sign-in succeeds, and a list comes back empty.
  FakeAdminTransport transportAnsweringPages() => FakeAdminTransport(
    (options) async => jsonResponse(
      options.path == '/v1/auth/login'
          ? loginJson()
          : pageJson(items: const [], total: 0),
    ),
  );

  setUp(() {
    transport = transportAnsweringPages();
  });

  HttpAdminRepository repository() => HttpAdminRepository(
    AdminApiClient(
      baseUrl: 'https://admin.peerpass.test',
      dio: Dio(BaseOptions(baseUrl: 'https://admin.peerpass.test'))
        ..httpClientAdapter = transport,
    ),
  );

  group('sign in', () {
    test('returns the tokens and address for a provisioned account', () async {
      transport = FakeAdminTransport(
        (options) async => jsonResponse(loginJson()),
      );

      final session = await repository().signIn('operator@peerpass.test', 'pw');

      expect(session.accessToken, 'access-token');
      expect(session.refreshToken, 'refresh-token');
      expect(session.email, 'operator@peerpass.test');
      expect(transport.requests.single.data, <String, dynamic>{
        'email': 'operator@peerpass.test',
        'password': 'pw',
      });
    });

    test('refuses an account without the admin role', () async {
      transport = FakeAdminTransport(
        (options) async => jsonResponse(loginJson(roles: const ['student'])),
      );

      await expectLater(
        repository().signIn('student@peerpass.test', 'pw'),
        throwsA(isA<AdminAccessException>()),
      );
    });

    test('reports a sign-in body with no tokens', () async {
      transport = FakeAdminTransport(
        (options) async =>
            jsonResponse(<String, dynamic>{'user': <String, dynamic>{}}),
      );

      await expectLater(
        repository().signIn('operator@peerpass.test', 'pw'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('lists', () {
    test('reads the requested page and maps every row', () async {
      transport = FakeAdminTransport((options) async {
        if (options.path == '/v1/auth/login') return jsonResponse(loginJson());
        return jsonResponse(
          pageJson(
            items: [
              userJson(email: 'ada.lovelace@peerpass.test'),
              userJson(email: 'grace.hopper@peerpass.test', fullName: ''),
            ],
            total: 137,
            limit: 2,
            offset: 4,
          ),
        );
      });
      await repository().signIn('operator@peerpass.test', 'pw');

      final page = await repository().users(
        const AdminPageRequest(page: 3, limit: 2),
      );

      expect(transport.requests.last.path, '/v1/admin/users');
      expect(transport.requests.last.queryParameters, <String, dynamic>{
        'offset': 4,
        'limit': 2,
      });
      expect(page.total, 137);
      expect(page.limit, 2);
      expect(page.offset, 4);
      expect(page.items.map((user) => user.email), <String>[
        'ada.lovelace@peerpass.test',
        'grace.hopper@peerpass.test',
      ]);
      // An account that never gave a name is still a row, not a gap.
      expect(page.items.last.name, isEmpty);
      expect(page.hasMore, isTrue);
    });

    test('reads each list from its own endpoint', () async {
      await repository().signIn('operator@peerpass.test', 'pw');

      await repository().auditEvents(const AdminPageRequest());
      await repository().competencies(const AdminPageRequest());
      await repository().tutorStandings(const AdminPageRequest());

      expect(transport.paths, <String>[
        '/v1/auth/login',
        '/v1/admin/audit-events',
        '/v1/admin/competencies',
        '/v1/admin/tutor-standings',
      ]);
    });

    test('narrows the queue on the server, not in the client', () async {
      await repository().signIn('operator@peerpass.test', 'pw');

      await repository().competencies(
        const AdminPageRequest(),
        status: CompetencyStatus.pending,
      );

      // The filter is a query parameter. Filtering the returned rows locally
      // would leave `total` describing a filter the API never applied, and the
      // pager would offer a second page that does not exist.
      expect(transport.requests.last.queryParameters, <String, dynamic>{
        'offset': 0,
        'limit': 50,
        'status': 'pending',
      });
    });

    test('sends no status at all when the queue is unfiltered', () async {
      await repository().signIn('operator@peerpass.test', 'pw');

      await repository().competencies(const AdminPageRequest());

      // Omitted rather than sent empty: `status=` is not a member of the API's
      // enum, so an empty value would be a 422 on the list the operator simply
      // opened.
      expect(transport.requests.last.queryParameters, <String, dynamic>{
        'offset': 0,
        'limit': 50,
      });
      expect(
        transport.requests.last.queryParameters.containsKey('status'),
        isFalse,
      );
    });

    test('keeps paging itself when a filter is set', () async {
      await repository().signIn('operator@peerpass.test', 'pw');

      await repository().competencies(
        const AdminPageRequest(page: 3, limit: 25),
        status: CompetencyStatus.rejected,
      );

      expect(transport.requests.last.queryParameters, <String, dynamic>{
        'offset': 50,
        'limit': 25,
        'status': 'rejected',
      });
    });
  });

  group('reviewing a competency', () {
    test('records a verification with no reason', () async {
      final competency = competencyFixture();
      await repository().signIn('operator@peerpass.test', 'pw');

      await repository().reviewCompetency(competency, 'verified');

      final request = transport.requests.last;
      expect(request.method, 'PATCH');
      expect(request.path, '/v1/admin/competencies/competency-1/review');
      expect(request.data, <String, dynamic>{'status': 'verified'});
    });

    test('records a rejection with its reason', () async {
      final competency = competencyFixture();
      await repository().signIn('operator@peerpass.test', 'pw');

      await repository().reviewCompetency(
        competency,
        'rejected',
        reason: 'The transcript is unreadable.',
      );

      expect(transport.requests.last.data, <String, dynamic>{
        'status': 'rejected',
        'rejection_reason': 'The transcript is unreadable.',
      });
    });
  });
}
