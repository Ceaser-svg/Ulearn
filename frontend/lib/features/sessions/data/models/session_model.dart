import 'package:flutter/foundation.dart';

/// Where a tutoring session has got to, as the API names the states.
///
/// Parsed from the wire rather than trusted as a string, and nullable on
/// [SessionModel] for the same reason `UserProfile` drops a role it does not
/// recognise: the API is still adding states (`no_show` arrived after the first
/// release), and a state this client has never heard of should render as an
/// unfamiliar label with no action attached rather than crash the sessions list
/// on launch. Which moves are legal is the API's business and is not encoded
/// here; this enum only says how a state is *displayed* and which of the two
/// lists on the sessions screen a row belongs in.
enum TutoringSessionStatus {
  scheduled('scheduled'),
  inProgress('in_progress'),
  completed('completed'),
  cancelled('cancelled'),
  noShow('no_show');

  TutoringSessionStatus(this.wireValue);

  /// The value the API uses on the wire.
  ///
  /// Held separately from [name] so renaming the Dart identifier cannot silently
  /// change what the client reads, and so a new case cannot be added without
  /// saying what the server calls it.
  final String wireValue;

  /// How the state is labelled to a student.
  ///
  /// A sentence rather than a bare token: the status is the one thing a user
  /// reads to decide what to do next, and "in_progress" is not that.
  String get label => switch (this) {
    scheduled => 'Scheduled',
    inProgress => 'In progress',
    completed => 'Completed',
    cancelled => 'Cancelled',
    noShow => 'No show',
  };

  /// Whether the session is still ahead of the user.
  ///
  /// Drives the Active/Past split on the sessions screen and nothing else. It is
  /// a grouping for display, deliberately not the transition table: the API
  /// decides which state may follow which, and a client that second-guessed it
  /// would offer a button the server then refuses.
  bool get isActive =>
      this == TutoringSessionStatus.scheduled ||
      this == TutoringSessionStatus.inProgress;

  /// The state parsed from a wire value, or null when it is not one we know.
  static TutoringSessionStatus? fromWire(String? value) {
    for (final status in TutoringSessionStatus.values) {
      if (status.wireValue == value) return status;
    }
    return null;
  }
}

/// A tutoring session, as the API returns it to either party.
///
/// A wire DTO and nothing more. The rules that decide what may happen to a
/// session -- who may start it, when it may be completed, whether a rating
/// exists -- live in the API, so this type carries no logic beyond "which of
/// the two parties is the reader", which is the one question a screen cannot
/// answer without asking the record.
@immutable
class SessionModel {
  const SessionModel({
    required this.id,
    required this.tuteeId,
    required this.tutorId,
    required this.courseUnitId,
    required this.topic,
    required this.statusWire,
    required this.createdAt,
    this.status,
    this.helpRequestId,
    this.scheduledStart,
    this.startedAt,
    this.endedAt,
    this.durationMinutes = 0,
    this.meetingLink,
    this.isRated = false,
  });

  /// Reads the wire form.
  ///
  /// The rule for tolerance: a field whose absence has one obvious neutral
  /// reading is defaulted, and a field a screen cannot render without is a
  /// [FormatException]. The id, the two parties, the unit, the topic, the status
  /// and the creation time are the ones a screen has nothing to fall back on;
  /// `is_rated` defaulting to false and `duration_minutes` to zero are both
  /// answers the API would give anyway, and a missing `scheduled_start` genuinely
  /// means an unscheduled session rather than a broken response.
  ///
  /// A [FormatException] here is a server fault, and the repository is what turns
  /// it into a user-facing failure: a bare cast error would arrive at a screen as
  /// a `TypeError`, get filed as an unknown error, and tell a student nothing.
  factory SessionModel.fromJson(Map<String, dynamic> json) {
    final id = _readId(json, 'id');
    final tuteeId = _readId(json, 'tutee_id');
    final tutorId = _readId(json, 'tutor_id');
    final courseUnitId = _readId(json, 'course_unit_id');
    final topic = json['topic'];
    final statusWire = json['status'];

    if (id == null ||
        tuteeId == null ||
        tutorId == null ||
        courseUnitId == null ||
        topic is! String ||
        statusWire is! String) {
      throw const FormatException(
        'session response was missing a required field',
      );
    }

    final createdAt = json['created_at'];
    if (createdAt is! String) {
      throw const FormatException('session response carried no creation time');
    }

    return SessionModel(
      id: id,
      tuteeId: tuteeId,
      tutorId: tutorId,
      courseUnitId: courseUnitId,
      topic: topic,
      statusWire: statusWire,
      status: TutoringSessionStatus.fromWire(statusWire),
      createdAt: DateTime.parse(createdAt),
      helpRequestId: _readId(json, 'help_request_id'),
      scheduledStart: _readDateTime(json, 'scheduled_start'),
      startedAt: _readDateTime(json, 'started_at'),
      endedAt: _readDateTime(json, 'ended_at'),
      durationMinutes: (json['duration_minutes'] as num?)?.toInt() ?? 0,
      meetingLink: _readString(json, 'meeting_link'),
      isRated: switch (json['is_rated']) {
        final bool rated => rated,
        // Not a boolean. The field has one obvious neutral reading, and refusing
        // the whole session over it would be worse than reading it as unrated.
        _ => false,
      },
    );
  }

  final String id;

  final String tuteeId;

  final String tutorId;

  /// The unit's public id.
  ///
  /// An id, and nothing more. `SessionResponse` does not carry the unit's code or
  /// title, so the client cannot name the unit on a session screen; see the
  /// detail screen for how that is presented until the response grows the field.
  final String courseUnitId;

  final String topic;

  /// The status exactly as the API spelled it.
  ///
  /// Kept beside the parsed [status] so an unrecognised state can be shown to
  /// the user verbatim rather than as a blank or a guessed label.
  final String statusWire;

  /// The parsed status, or null when the API named one this client predates.
  final TutoringSessionStatus? status;

  final String? helpRequestId;

  final DateTime? scheduledStart;

  final DateTime? startedAt;

  final DateTime? endedAt;

  final int durationMinutes;

  /// The two-digit handshake pin the API generated.
  ///
  /// Shown to the tutee and never to the tutor. The API sends it to both parties
  /// because they share one response shape, which means the pin is not a secret
  /// from a client that reads the payload -- the handshake proves the tutor was
  /// in the room, not that they did not read the API. Recorded here so the
  /// limitation is visible in the one place that could act on it.

  /// The meeting link the tutor shared, if any.
  ///
  /// Copyable rather than tappable on purpose: the app ships no link-opening
  /// dependency, and the agreed substitute for in-app chat is a value the student
  /// can hand to a browser.
  final String? meetingLink;

  /// Whether a rating exists for this session yet.
  ///
  /// A flag and not the rating. `GET /v1/ratings/me/recent` returns ratings
  /// *received* by a tutor, so a client has no endpoint that returns the rating
  /// the signed-in user gave for a given session; the score itself is only known
  /// to the client that just submitted it, and is held on the detail screen for
  /// as long as that screen is open.
  final bool isRated;

  final DateTime createdAt;

  /// Whether [publicId] is the student in this session.
  ///
  /// A comparison and not a stored role, because the API names both parties in
  /// every response and the client is one of them.
  bool isTutee(String publicId) => tuteeId == publicId;

  /// Whether [publicId] is the tutor in this session.
  bool isTutor(String publicId) => tutorId == publicId;

  /// The other party's public id, given who is asking.
  ///
  /// Null when [publicId] is neither party, which the API does not allow but
  /// which a stale cached profile could produce; the screens treat null as "say
  /// nothing" rather than naming the reader as the other party.
  String? otherPartyId(String publicId) {
    if (isTutee(publicId)) return tutorId;
    if (isTutor(publicId)) return tuteeId;
    return null;
  }

  /// The status as a student reads it.
  String get statusLabel => status?.label ?? statusWire;

  /// Whether the session is still ahead of the user.
  ///
  /// False for a status this client does not recognise: an unfamiliar state must
  /// not be presented as something to act on.
  bool get isActive => status?.isActive ?? false;

  SessionModel copyWith({
    String? statusWire,
    TutoringSessionStatus? status,
    int? durationMinutes,
    String? meetingLink,
    bool? isRated,
  }) {
    return SessionModel(
      id: id,
      tuteeId: tuteeId,
      tutorId: tutorId,
      courseUnitId: courseUnitId,
      topic: topic,
      statusWire: statusWire ?? this.statusWire,
      status: status ?? this.status,
      helpRequestId: helpRequestId,
      scheduledStart: scheduledStart,
      startedAt: startedAt,
      endedAt: endedAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      meetingLink: meetingLink ?? this.meetingLink,
      isRated: isRated ?? this.isRated,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionModel &&
          other.id == id &&
          other.tuteeId == tuteeId &&
          other.tutorId == tutorId &&
          other.courseUnitId == courseUnitId &&
          other.topic == topic &&
          other.statusWire == statusWire &&
          other.helpRequestId == helpRequestId &&
          other.scheduledStart == scheduledStart &&
          other.startedAt == startedAt &&
          other.endedAt == endedAt &&
          other.durationMinutes == durationMinutes &&
          other.meetingLink == meetingLink &&
          other.isRated == isRated &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    tuteeId,
    tutorId,
    courseUnitId,
    topic,
    statusWire,
    helpRequestId,
    scheduledStart,
    startedAt,
    endedAt,
    durationMinutes,
    meetingLink,
    isRated,
    createdAt,
  );

  @override
  String toString() => 'SessionModel($id, $topic, $statusWire)';
}

/// A public id, or null when the field is absent or not a string.
///
/// A non-string is treated as absent rather than coerced, on the same grounds as
/// an unrecognised status: a field that arrives as something else is a field this
/// client cannot use, and pretending otherwise would put a number in an id field.
String? _readId(Map<String, dynamic> json, String key) =>
    _readString(json, key);

String? _readString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  return null;
}

/// A timestamp, or null when there is not one yet.
///
/// [DateTime.parse] throwing on a malformed value is deliberate and left to
/// propagate: an unparseable timestamp is a server fault, and the repository
/// reports it as one.
DateTime? _readDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return DateTime.parse(value as String);
}

@immutable
/// The handshake pin, as the tutor reads it out.
///
/// Its own type rather than a field on `SessionModel`, because the pin is not
/// part of a session: it belongs to one party. While it sat on the model, the
/// tutee's own session screen carried their pin, and the whole handshake could be
/// completed by one person without the other ever being there.
class SessionPinModel {
  const SessionPinModel({
    required this.sessionId,
    required this.sessionPin,
    required this.attemptsRemaining,
  });

  /// Reads the wire form of `GET /v1/sessions/{id}/pin`.
  ///
  /// The pin itself is required. This response exists only to carry it, so its
  /// absence is a server fault rather than a state to render around -- unlike
  /// every optional field on `SessionModel`, where absence has a neutral reading.
  factory SessionPinModel.fromJson(Map<String, dynamic> json) {
    final sessionId = json['session_id'];
    final pin = json['session_pin'];
    if (sessionId is! String || pin is! String) {
      throw FormatException('PIN response is missing its session or pin', json);
    }
    final remaining = json['attempts_remaining'];
    if (remaining is! int) {
      throw FormatException(
        'PIN response is missing its attempts remaining count',
        json,
      );
    }
    return SessionPinModel(
      sessionId: sessionId,
      sessionPin: pin,
      attemptsRemaining: remaining,
    );
  }

  final String sessionId;
  final String sessionPin;

  /// Wrong entries left before the tutee is put on a cooldown.
  ///
  /// Shown to the tutor so they can stop guessing on the tutee's behalf. The
  /// lockout itself is the API's: a ceiling counted on a device is one a student
  /// clears by reinstalling the app.
  final int attemptsRemaining;

  @override
  bool operator ==(Object other) =>
      other is SessionPinModel &&
      other.sessionId == sessionId &&
      other.sessionPin == sessionPin &&
      other.attemptsRemaining == attemptsRemaining;

  @override
  int get hashCode => Object.hash(sessionId, sessionPin, attemptsRemaining);

  @override
  String toString() =>
      'SessionPinModel($sessionId, attempts: $attemptsRemaining)';
}
