import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/app/admin_app.dart';

void main() {
  testWidgets('shows the administrator sign-in form', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AdminApp()));

    expect(find.text('MUST operations'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
