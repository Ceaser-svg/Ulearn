import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/data/repositories/fake_sessions_repository.dart';

/// A fake that behaves the way the API does about the things a test cannot see.
///
/// The repository tests assert on the wire. This one asserts on the seam widget
/// tests resolve, and a fake that quietly diverges from the API shows up as a
/// screen test passing against behaviour the server does not have.
void main() {
  FakeSessionsRepository repository() {
    return FakeSessionsRepository()
      ..withPendingStudent('student-1', tutorId: 'tutor-1');
  }

  Future<SessionModel> confirm(
    FakeSessionsRepository fake, {
    String requestId = 'request-1',
    int durationMinutes = 45,
  }) {
    return fake.confirmRequest(
      requestId: requestId,
      courseUnitId: 'unit-1',
      topic: 'eigenvalues',
      durationMinutes: durationMinutes,
    );
  }

  group('confirming a request', () {
    test('records what was sent, so a screen test can check the real call', () async {
      final fake = repository();

      await confirm(fake, durationMinutes: 75);

      expect(fake.confirmations, hasLength(1));
      expect(fake.confirmations.single.requestId, 'request-1');
      expect(fake.confirmations.single.courseUnitId, 'unit-1');
      expect(fake.confirmations.single.topic, 'eigenvalues');
      expect(fake.confirmations.single.durationMinutes, 75);
    });

    test('returns a scheduled session belonging to the student who asked', () async {
      final fake = repository();

      final created = await confirm(fake);

      expect(created.status, TutoringSessionStatus.scheduled);
      expect(created.helpRequestId, 'request-1');
      expect(created.tuteeId, 'student-1');
      expect(created.tutorId, 'tutor-1');
      expect(created.durationMinutes, 45);
      // A PIN is issued, and it is not on the session. The fake has to serve it
      // the way the API does -- through `revealPin`, tutor-only -- so a screen
      // test cannot pass by reading the pin off a payload a tutee could also read.
      final pin = await fake.revealPin(sessionId: created.id);
      expect(pin.sessionPin, hasLength(2));
      expect(pin.attemptsRemaining, FakeSessionsRepository.maxPinAttempts);
    });

    test('the created session joins the list the screen already has', () async {
      final fake = repository();
      expect(fake.sessions, isEmpty);

      final created = await confirm(fake);

      expect(fake.sessions.map((s) => s.id), [created.id]);
    });

    test('a second confirmation is refused, as the API refuses it', () async {
      final fake = repository();
      await confirm(fake);

      // The API's unique constraint on the request is the real guarantee. A fake
      // that let a second confirmation through would let a screen ship a button
      // that turns one question into two sessions.
      await expectLater(confirm(fake), throwsA(isA<ConflictFailure>()));
      expect(fake.sessions, hasLength(1));
    });

    test('a zero length is refused the way the API refuses it', () async {
      final fake = repository();

      await expectLater(
        confirm(fake, durationMinutes: 0),
        throwsA(
          isA<ValidationFailure>().having(
            (failure) => failure.fieldErrors,
            'fieldErrors',
            {'duration_minutes': 'must be at least 1'},
          ),
        ),
      );
    });

    test('a refusal is still recorded, so a test can prove it was attempted', () async {
      final fake = repository();

      await expectLater(confirm(fake, durationMinutes: 0), throwsA(isA<Failure>()));

      // Recorded before the refusal. A fake that only recorded successes would let
      // a screen test pass while the real request was never sent -- which is the
      // exact shape of a bug that a "the button does nothing" report produces.
      expect(fake.confirmations, hasLength(1));
    });
  });
}
