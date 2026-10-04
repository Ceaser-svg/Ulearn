import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/features/sessions/data/models/rating_model.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';

/// A session body shaped like `SessionResponse`.
Map<String, dynamic> _session({
  String id = 'session-1',
  String status = 'scheduled',
  String? scheduledStart = '2026-03-04T09:00:00Z',
  String? startedAt,
  String? endedAt,
  String? sessionPin = '42',
  String? meetingLink = 'https://meet.peerpass.test/abc',
  bool isRated = false,
}) {
  return {
    'id': id,
    'help_request_id': 'request-1',
    'tutee_id': 'student-1',
    'tutor_id': 'tutor-1',
    'course_unit_id': 'unit-1',
    'topic': 'Second order ODEs',
    'status': status,
    'duration_minutes': 60,
    'is_rated': isRated,
    'created_at': '2026-03-01T08:00:00Z',
    'scheduled_start': scheduledStart,
    'started_at': startedAt,
    'ended_at': endedAt,
    'session_pin': sessionPin,
    'meeting_link': meetingLink,
  };
}

void main() {
  group('reading a session', () {
    test('carries every field the screens render', () {
      final session = SessionModel.fromJson(
        _session(startedAt: '2026-03-04T09:05:00Z', endedAt: '2026-03-04T10:00:00Z'),
      );

      expect(session.id, 'session-1');
      expect(session.tuteeId, 'student-1');
      expect(session.tutorId, 'tutor-1');
      expect(session.courseUnitId, 'unit-1');
      expect(session.topic, 'Second order ODEs');
      expect(session.status, TutoringSessionStatus.scheduled);
      expect(session.durationMinutes, 60);
      expect(session.isRated, isFalse);
      expect(session.meetingLink, 'https://meet.peerpass.test/abc');
      expect(session.scheduledStart, DateTime.utc(2026, 3, 4, 9));
      expect(session.startedAt, DateTime.utc(2026, 3, 4, 9, 5));
      expect(session.endedAt, DateTime.utc(2026, 3, 4, 10));
    });

    test('tells the two parties apart', () {
      final session = SessionModel.fromJson(_session());

      expect(session.isTutee('student-1'), isTrue);
      expect(session.isTutor('student-1'), isFalse);
      expect(session.otherPartyId('student-1'), 'tutor-1');
      expect(session.otherPartyId('tutor-1'), 'student-1');
      // A stale profile that is neither party gets nothing rather than being
      // handed the reader's own id back as "the other participant".
      expect(session.otherPartyId('someone-else'), isNull);
    });

    test('groups by what is still ahead of the user', () {
      // The Active/Past split on the list screen and the single card on home both
      // read this, so it is pinned per state rather than through a widget.
      bool active(String status) =>
          SessionModel.fromJson(_session(status: status)).isActive;

      expect(active('scheduled'), isTrue);
      expect(active('in_progress'), isTrue);
      expect(active('completed'), isFalse);
      expect(active('cancelled'), isFalse);
      // A no-show is a session that did not happen. It is not "upcoming", and
      // showing it as something to act on would be the wrong kind of hopeful.
      expect(active('no_show'), isFalse);
    });

    test('a state this client predates is shown, and treated as inert', () {
      // `no_show` did not exist in the first release. A client that threw on it
      // would take down the whole sessions list for a state the API considers
      // ordinary; a client that guessed a neighbour of it would offer a button the
      // server then refuses.
      final session = SessionModel.fromJson(_session(status: 'rescheduled'));

      expect(session.status, isNull);
      expect(session.statusWire, 'rescheduled');
      // Verbatim rather than blank, so a user can report what they are seeing.
      expect(session.statusLabel, 'rescheduled');
      expect(session.isActive, isFalse);
    });

    test('a key that is absent reads as absent, not as broken', () {
      // What the API actually sends for a session that was never scheduled: the
      // key is missing rather than null. A parser that required the key would
      // refuse to show an unscheduled session at all.
      final session = SessionModel.fromJson(
        _session()
          ..remove('scheduled_start')
          ..remove('started_at')
          ..remove('ended_at')
          ..remove('meeting_link'),
      );

      expect(session.scheduledStart, isNull);
      expect(session.startedAt, isNull);
      expect(session.endedAt, isNull);
      expect(session.meetingLink, isNull);
    });

    test('a key sent as null reads as absent too', () {
      // The other shape the same field can arrive in, depending on the serializer.
      // Assigned rather than omitted, so the keys really are in the map holding
      // null -- which is not the same thing as the keys being missing.
      final session = SessionModel.fromJson(
        _session()
          ..['scheduled_start'] = null
          ..['started_at'] = null
          ..['ended_at'] = null
          ..['meeting_link'] = null,
      );

      expect(session.scheduledStart, isNull);
      expect(session.startedAt, isNull);
      expect(session.endedAt, isNull);
      expect(session.meetingLink, isNull);
      // A null in one optional field does not take the rest of the record with it.
      // `duration_minutes` is not one of the fields nulled above, so it proves the
      // other four were read individually rather than the parse falling over.
      expect(session.durationMinutes, 60);
    });

    test('an empty id is treated as missing, not as an id', () {
      expect(
        () => SessionModel.fromJson(_session(id: '')),
        throwsA(isA<FormatException>()),
      );
    });

    test('a response missing something a screen needs is a format error', () {
      // The repository turns this into a user-facing failure. Left as a cast error
      // it would arrive at a screen as a TypeError, be filed as an unknown error,
      // and tell a student nothing at all.
      final withoutStatus = _session()..remove('status');

      expect(
        () => SessionModel.fromJson(withoutStatus),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-boolean is_rated reads as unrated rather than failing', () {
      final session = SessionModel.fromJson(
        _session()..['is_rated'] = 'yes',
      );

      expect(session.isRated, isFalse);
    });

    test('an unparseable timestamp is a server fault, not a silent default', () {
      expect(
        () => SessionModel.fromJson(_session()..['created_at'] = 'yesterday'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('reading a rating', () {
    test('carries the score, the note, and both parties', () {
      final rating = RatingModel.fromJson(const {
        'id': 'rating-1',
        'session_id': 'session-1',
        'rater_id': 'student-1',
        'ratee_id': 'tutor-1',
        'score': 5,
        'feedback_text': 'Explained the integrating factor properly.',
        'created_at': '2026-03-04T11:00:00Z',
      });

      expect(rating.sessionId, 'session-1');
      expect(rating.score, 5);
      expect(rating.scoreLabel, '5 out of 5');
      expect(rating.feedbackText, 'Explained the integrating factor properly.');
    });

    test('a rating with no note reads as having none', () {
      final rating = RatingModel.fromJson(const {
        'id': 'rating-1',
        'session_id': 'session-1',
        'rater_id': 'student-1',
        'ratee_id': 'tutor-1',
        'score': 3,
        'created_at': '2026-03-04T11:00:00Z',
      });

      expect(rating.feedbackText, isNull);
    });

    test('a rating with no score is a format error', () {
      expect(
        () => RatingModel.fromJson(const {
          'id': 'rating-1',
          'session_id': 'session-1',
          'rater_id': 'student-1',
          'ratee_id': 'tutor-1',
          'created_at': '2026-03-04T11:00:00Z',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
