import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass_admin/core/models/admin_competency.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';
import 'package:peerpass_admin/features/admin/presentation/providers/admin_repository_provider.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/competencies_screen.dart';

import '../../../../support/fake_admin_repository.dart';
import '../../../../support/fixtures.dart';

// The review queue is the console's widest table, so it is the one that finds
// out when the shared record table stops fitting. Every width in this list has
// been an overflow at some point, and an overflow is invisible in review until
// it is a red stripe in front of an operator.

/// The widths worth checking: either side of the card breakpoint, and the
/// tablet and laptop sizes in between.
const widths = <double>[721, 900, 1100, 1600];

void main() {
  for (final width in widths) {
    testWidgets('the queue fits a $width wide window', (tester) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = FakeAdminRepository(
        competencyRows: <AdminCompetency>[
          competencyFixture(rejectionReason: 'A long enough reason to wrap.'),
        ],
      );
      final container = ProviderContainer.test(
        overrides: [adminRepositoryProvider.overrideWithValue(repository)],
      );
      container
          .read(sessionProvider.notifier)
          .signedIn(
            const AdminSession(
              accessToken: 'a',
              refreshToken: 'r',
              email: 'o@peerpass.test',
            ),
          );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAdminTheme(),
            home: const Scaffold(body: CompetenciesScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing overflowed: the complaint is thrown during layout, so a clean
      // run is the assertion.
      expect(tester.takeException(), isNull);
    });
  }
}
