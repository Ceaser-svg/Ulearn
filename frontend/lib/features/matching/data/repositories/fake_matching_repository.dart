import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit.dart';
import 'package:peerpass/features/matching/data/models/help_request.dart';
import 'package:peerpass/features/matching/data/models/match_result.dart';
import 'package:peerpass/features/matching/data/repositories/matching_repository.dart';

/// In-memory stand-in for the matching endpoints.
///
/// What widget tests resolve, because a widget test has no server to talk to. It
/// implements the repository's shape rather than the datasource's, because that
/// is the seam a test cares about: overriding the repository is the only
/// composition the app supports.
///
/// A fake and not a stub in the two places a stub would hide a bug. It records
/// what it was asked, so a test can prove the screen sent the unit it was given
/// and the widening flag the student chose. And its default answer is "nobody is
/// eligible for this unit" -- the honest response -- rather than an empty
/// response that reads as success with nothing in it.
class FakeMatchingRepository implements MatchingRepository {
  FakeMatchingRepository({
    List<CourseUnit> courseUnits = const [],
    this.onSuggestions,
    this.onMyHelpRequests,
    this.onCreateHelpRequest,
    this.onSelectTutor,
    this.onRequestsAwaitingMe,
    this.onDeclineHelpRequest,
    this.defaultResult,
  }) : _courseUnits = List<CourseUnit>.of(courseUnits);

  final List<CourseUnit> _courseUnits;

  final List<HelpRequest> _requests = <HelpRequest>[];

  /// The answer every query gets when [onSuggestions] does not script one.
  final MatchResult? defaultResult;

  /// Answers each call from the arguments it was given.
  ///
  /// The seam for a test that needs the answer to depend on the query -- a
  /// widened search, a unit with nobody eligible -- because the same screen has
  /// to render both and a repository that returned one fixed body could only
  /// prove half of it.
  final MatchResult Function({
    required String courseUnitId,
    required bool widenToSubject,
  })?
  onSuggestions;

  /// Stands in for the API's answer to creating a request.
  ///
  /// The seam for a request that is refused -- a topic the API will not take, a
  /// student with no university -- which is a path the screen has to render and
  /// the in-memory default cannot produce. Return null to let the fake make one.
  final Future<HelpRequest?> Function({
    required String courseUnitId,
    required String topic,
    String? description,
  })?
  onCreateHelpRequest;

  /// Stands in for the student's own requests.
  ///
  /// The seam for a request whose status has moved on without this device doing
  /// anything -- a tutor who declined, a session that was confirmed -- which is
  /// the only way a waiting screen can be shown becoming untrue.
  final Future<List<HelpRequest>?> Function()? onMyHelpRequests;

  /// Stands in for the API's answer to naming a tutor.
  ///
  /// The seam for the refusal that matters most here: a tutor who is not among
  /// the candidates for the request's unit is rejected by the API however
  /// confidently the client names them, and a screen has to be able to show that
  /// without a server to send it. Return null to let the fake accept.
  final Future<HelpRequest?> Function({
    required String requestId,
    required String candidateTutorId,
  })?
  onSelectTutor;

  /// Stands in for the tutor's outstanding requests.
  ///
  /// The seam for an empty list and for a failure, neither of which is what this
  /// fake's own memory holds in a test that only created requests on the student
  /// side. Return null to let the fake answer from memory.
  final Future<List<HelpRequest>?> Function()? onRequestsAwaitingMe;

  /// Stands in for the API's answer to turning a request down.
  ///
  /// Return null to let the fake decline in memory.
  final Future<HelpRequest?> Function({required String requestId})?
  onDeclineHelpRequest;

  /// Every `(courseUnitId, widenToSubject)` pair asked for, in order.
  final List<({String courseUnitId, bool widenToSubject})> queries = [];

  /// Every request created, in order.
  final List<({String courseUnitId, String topic, String? description})>
  createdRequests = [];

  /// Every `(requestId, candidateTutorId)` pair chosen, in order.
  final List<({String requestId, String candidateTutorId})> selections = [];

  /// Every request id turned down, in order.
  final List<String> declines = [];

  /// The course units the picker offers.
  List<CourseUnit> get catalogue => List<CourseUnit>.unmodifiable(_courseUnits);

  @override
  Future<List<CourseUnit>> courseUnits({
    String? universityId,
    String? subjectId,
  }) async => List<CourseUnit>.unmodifiable(_courseUnits);

  @override
  Future<MatchResult> suggestions({
    required String courseUnitId,
    bool widenToSubject = false,
    int? limit,
  }) async {
    queries.add((courseUnitId: courseUnitId, widenToSubject: widenToSubject));

    final scripted = onSuggestions?.call(
      courseUnitId: courseUnitId,
      widenToSubject: widenToSubject,
    );
    if (scripted != null) return scripted;

    return defaultResult ??
        MatchResult(
          courseUnitId: courseUnitId,
          widened: false,
          candidates: const [],
          exclusions: const [],
          noEligibleTutors: true,
          generatedAt: DateTime.utc(2026, 3, 4, 9, 12),
        );
  }

  @override
  Future<HelpRequest> createHelpRequest({
    required String courseUnitId,
    required String topic,
    String? description,
  }) async {
    createdRequests.add((
      courseUnitId: courseUnitId,
      topic: topic,
      description: description,
    ));
    if (onCreateHelpRequest != null) {
      final scripted = await onCreateHelpRequest!(
        courseUnitId: courseUnitId,
        topic: topic,
        description: description,
      );
      if (scripted != null) return scripted;
    }

    // Kept in memory rather than answered and forgotten, so a test that creates
    // a request and then selects against it exercises the two calls in the order
    // a real client makes them. A fake that dropped the request would let a screen
    // select against an id that no longer exists anywhere and still pass.
    final request = HelpRequest(
      id: _nextId(),
      tuteeId: 'tutee-1',
      courseUnitId: courseUnitId,
      topic: topic,
      description: description,
      statusWire: HelpRequestStatus.open.wireValue,
      status: HelpRequestStatus.open,
      createdAt: DateTime.utc(2026, 3, 4, 9, 12),
    );
    _requests.add(request);
    return request;
  }

  @override
  Future<HelpRequest> selectTutor({
    required String requestId,
    required String candidateTutorId,
  }) async {
    selections.add((requestId: requestId, candidateTutorId: candidateTutorId));
    if (onSelectTutor != null) {
      final scripted = await onSelectTutor!(
        requestId: requestId,
        candidateTutorId: candidateTutorId,
      );
      if (scripted != null) return scripted;
    }

    final index = _requests.indexWhere((request) => request.id == requestId);
    if (index < 0) {
      throw const NotFoundFailure('That help request could not be found.');
    }
    final updated = _copyWithSelection(_requests[index], candidateTutorId);
    _requests[index] = updated;
    return updated;
  }

  @override
  Future<List<HelpRequest>> myHelpRequests() async {
    if (onMyHelpRequests != null) {
      final scripted = await onMyHelpRequests!();
      if (scripted != null) return scripted;
    }
    return List<HelpRequest>.unmodifiable(_requests);
  }

  @override
  Future<List<HelpRequest>> requestsAwaitingMe() async {
    if (onRequestsAwaitingMe != null) {
      final scripted = await onRequestsAwaitingMe!();
      if (scripted != null) return scripted;
    }
    return [
      for (final request in _requests)
        if (request.isAwaitingTutor) request,
    ];
  }

  @override
  Future<HelpRequest> declineHelpRequest({required String requestId}) async {
    declines.add(requestId);
    if (onDeclineHelpRequest != null) {
      final scripted = await onDeclineHelpRequest!(requestId: requestId);
      if (scripted != null) return scripted;
    }

    final index = _requests.indexWhere((request) => request.id == requestId);
    if (index < 0) {
      throw const NotFoundFailure('That help request could not be found.');
    }
    // The chosen tutor is kept, as the API keeps it: a decline is a decision by
    // a named person, and a fake that dropped the name would make the tutor's own
    // screen look like a student had simply cancelled.
    final updated = HelpRequest(
      id: _requests[index].id,
      tuteeId: _requests[index].tuteeId,
      courseUnitId: _requests[index].courseUnitId,
      topic: _requests[index].topic,
      description: _requests[index].description,
      statusWire: HelpRequestStatus.declined.wireValue,
      status: HelpRequestStatus.declined,
      matchedTutorId: _requests[index].matchedTutorId,
      createdAt: _requests[index].createdAt,
    );
    _requests[index] = updated;
    return updated;
  }

  /// Puts a request into this fake's memory, as though the API had it.
  ///
  /// For the tutor's screen, which lists requests this client never created: the
  /// student who made them is a different account, and a widget test has only one.
  void seedAwaiting(HelpRequest request) => _requests.add(request);

  /// Every request this fake currently holds, in the order they were added.
  List<HelpRequest> get requests => List<HelpRequest>.unmodifiable(_requests);

  /// The request the next [createHelpRequest] will return, as a public id.
  String _nextId() => 'help-request-${_requests.length + 1}';

  HelpRequest _copyWithSelection(HelpRequest request, String candidateTutorId) {
    return HelpRequest(
      id: request.id,
      tuteeId: request.tuteeId,
      courseUnitId: request.courseUnitId,
      topic: request.topic,
      description: request.description,
      statusWire: HelpRequestStatus.pendingConfirmation.wireValue,
      status: HelpRequestStatus.pendingConfirmation,
      matchedTutorId: candidateTutorId,
      createdAt: request.createdAt,
    );
  }
}
