import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/app/admin_app.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/admin_shell.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/sign_in_screen.dart';

import '../support/fake_admin_transport.dart';
import '../support/fixtures.dart';

const _baseUrl = 'https://admin.peerpass.test';

const _session = AdminSession(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  email: 'operator@peerpass.test',
);

void main() {
  /// A console whose transport is [transport], signed in as an administrator.
  ///
  /// The transport and the client are the shipping ones; only the socket is
  /// replaced, so the session gate, the list controllers, the HTTP repository,
  /// the refresh, and the expiry wiring are all the real thing.
  ProviderContainer signedInConsole(FakeAdminTransport transport) {
    final container = ProviderContainer.test(
      overrides: [
        adminDioProvider.overrideWithValue(
          Dio(BaseOptions(baseUrl: _baseUrl))..httpClientAdapter = transport,
        ),
      ],
    );
    // The sign-in the operator completed before this test started.
    container.read(adminApiClientProvider).adoptSession(_session);
    container.read(sessionProvider.notifier).signedIn(_session);
    return container;
  }

  testWidgets('shows the sign-in view with no session', (tester) async {
    final container = ProviderContainer.test();

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const AdminApp()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.byType(AdminShell), findsNothing);
  });

  testWidgets('shows the shell once an administrator is signed in', (
    tester,
  ) async {
    final transport = FakeAdminTransport(
      (options) async => jsonResponse(pageJson(items: const [], total: 0)),
    );
    final container = signedInConsole(transport);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const AdminApp()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AdminShell), findsOneWidget);
    expect(find.byType(SignInScreen), findsNothing);
  });

  testWidgets('a refresh the server refuses lands on the sign-in view', (
    tester,
  ) async {
    // Every authenticated read and every refresh attempt is rejected.
    final transport = FakeAdminTransport(
      (options) async =>
          jsonResponse(<String, dynamic>{'detail': 'expired'}, statusCode: 401),
    );
    final container = signedInConsole(transport);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const AdminApp()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.byType(AdminShell), findsNothing);
    expect(container.read(sessionProvider), isNull);
  });

  testWidgets('a refused read that cannot refresh lands on sign-in once', (
    tester,
  ) async {
    var signedOut = 0;
    // Every authenticated read and every refresh attempt is rejected.
    final transport = FakeAdminTransport(
      (options) async =>
          jsonResponse(<String, dynamic>{'detail': 'expired'}, statusCode: 401),
    );
    final container = signedInConsole(transport)
      ..listen(sessionProvider, (previous, next) {
        if (next == null) signedOut++;
      });

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const AdminApp()),
    );
    await tester.pumpAndSettle();
    // Frames after the transition, to catch a sign-out loop.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(signedOut, 1);
    // The console stopped asking once there was no session to ask with.
    expect(
      transport.paths.where((path) => path == '/v1/admin/users'),
      hasLength(1),
    );
    expect(
      transport.paths.where((path) => path == '/v1/auth/refresh'),
      hasLength(1),
    );
  });

  testWidgets('signing out returns the operator to the sign-in view', (
    tester,
  ) async {
    final transport = FakeAdminTransport(
      (options) async => jsonResponse(pageJson(items: const [], total: 0)),
    );
    final container = signedInConsole(transport);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const AdminApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.byType(AdminShell), findsNothing);
    expect(container.read(sessionProvider), isNull);
  });
}
