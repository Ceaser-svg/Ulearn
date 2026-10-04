import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/widgets/failure_view.dart';

/// Pumps a [FailureView] and returns what a student could act on.
Future<void> pumpFailure(
  WidgetTester tester,
  Failure failure, {
  VoidCallback? onRetry,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FailureView(failure: failure, onRetry: onRetry),
      ),
    ),
  );
}

void main() {
  group('FailureView', () {
    testWidgets('offers a retry when one can help', (tester) async {
      var retried = 0;
      await pumpFailure(
        tester,
        const NetworkFailure(),
        onRetry: () => retried++,
      );

      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });

    testWidgets('hides the lockout wait and the retry during it', (tester) async {
      // A retry button offered during a lockout invites a student to spend
      // their remaining budget rediscovering the refusal, and on the sign-in
      // path each attempt is another hash the server discards.
      await pumpFailure(
        tester,
        ThrottledFailure(
          'Too many attempts. Try again in 15 minutes.',
          retryAfter: const Duration(minutes: 15),
          retryAt: DateTime.now().add(const Duration(minutes: 15)),
        ),
        onRetry: () {},
      );

      expect(find.text('Try again'), findsNothing);
      expect(find.textContaining('Try again in 15 minutes'), findsOneWidget);
    });

    testWidgets('counts the wait down', (tester) async {
      await pumpFailure(
        tester,
        ThrottledFailure(
          'Too many attempts.',
          retryAfter: const Duration(seconds: 90),
          retryAt: DateTime.now().add(const Duration(seconds: 90)),
        ),
      );

      expect(find.text('1:30'), findsOneWidget);

      await tester.pump(const Duration(seconds: 45));
      expect(find.text('0:45'), findsOneWidget);
    });

    testWidgets('offers retry once the wait has elapsed', (tester) async {
      var retried = 0;
      await pumpFailure(
        tester,
        ThrottledFailure(
          'Too many attempts.',
          retryAfter: const Duration(seconds: 2),
          retryAt: DateTime.now().add(const Duration(seconds: 2)),
        ),
        onRetry: () => retried++,
      );

      expect(find.text('Try again'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('You can try again now.'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });

    testWidgets('stops ticking once the wait is over', (tester) async {
      // A ticker left running past the end of its life rebuilds a widget nobody
      // is watching, and the test framework fails on any pending timer.
      await pumpFailure(
        tester,
        ThrottledFailure(
          'Too many attempts.',
          retryAfter: const Duration(seconds: 1),
          retryAt: DateTime.now().add(const Duration(seconds: 1)),
        ),
      );

      await tester.pump(const Duration(seconds: 2));

      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('says nothing about timing when the server said nothing', (
      tester,
    ) async {
      // No usable Retry-After is legal. Inventing a countdown the server never
      // promised would be a lie; a clock reading 0:00 would be a worse one.
      await pumpFailure(
        tester,
        const ThrottledFailure('Too many attempts. Wait a moment.'),
      );

      expect(find.textContaining('Try again in'), findsNothing);
      expect(find.textContaining('0:'), findsNothing);
      expect(find.textContaining('Wait a moment'), findsOneWidget);
    });

    testWidgets('gives every failure type a presentation', (tester) async {
      // The exhaustive switch in FailureView is the mechanism; this asserts it
      // still renders, so a new type cannot quietly reach a blank screen.
      final failures = <Failure>[
        const NetworkFailure(),
        const AuthFailure(),
        const ValidationFailure('bad'),
        const NotFoundFailure(),
        const ConflictFailure(),
        const ThrottledFailure('slow down'),
        const ServerFailure(),
        const CancelledFailure(),
        const UnknownFailure(),
      ];

      for (final failure in failures) {
        await pumpFailure(tester, failure);
        // Exhaustive-switch coverage is a compile-time guarantee, so what is
        // worth asserting here is that each type actually reaches the screen
        // with its own wording rather than a blank or shared one.
        expect(
          find.text(failure.message),
          findsOneWidget,
          reason: '$failure did not render its own message',
        );
        expect(find.byType(Icon), findsWidgets, reason: '$failure has no icon');
        expect(tester.takeException(), isNull, reason: '$failure threw');
      }
    });
  });
}
