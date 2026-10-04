import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// For `FutureProviderFamily` alone. The name of the provider's own type is the
// annotation below, and a record-typed family argument is one of the shapes the
// `specify_nonobvious_property_types` rule will not infer for itself. The family
// classes are not on `flutter_riverpod.dart`, so this is the library that has
// them.
import 'package:flutter_riverpod/misc.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/matching/data/models/help_request.dart';
import 'package:peerpass/features/matching/data/models/match_result.dart';
import 'package:peerpass/features/matching/data/repositories/matching_repository.dart';

/// One search for tutors, as the pair of things that can change it.
///
/// A record rather than a class because it is only ever a cache key: two searches
/// with the same two fields are the same search, and value equality is what lets
/// the family reuse the first answer instead of asking again for a student who
/// toggled the widening switch back and forth.
typedef MatchQuery = ({String courseUnitId, bool widenToSubject});

/// The course units the picker offers.
///
/// Read here rather than reused from the auth feature. The dependency rules only
/// let one feature reach another through that feature's repository contract, and
/// a shared catalogue would need a home in `core/` that has no reason to know
/// what a course unit is.
final courseUnitOptionsProvider = FutureProvider<List<CourseUnit>>((ref) {
  final profile = ref.watch(sessionControllerProvider).profile;
  return ref
      .watch(matchingRepositoryProvider)
      .courseUnits(
        universityId: profile?.universityId,
        subjectId: profile?.facultyId,
      );
}, retry: (retryCount, error) => null);

/// The tutors the API will propose for one query.
///
/// A family keyed by [MatchQuery], so the results screen, a re-search with
/// widening on, and a second unit in the same session are three separate
/// answers rather than one slot each overwriting the other. [AsyncValue] already
/// carries the three states the screen renders -- waiting, the answer, and the
/// reason there is none -- and a "nobody is eligible" answer is one of those
/// answers, not an error.
///
/// The automatic retry is off for the reason `sessionListProvider` switches it
/// off: a screen with a "Try again" button must not also be re-requesting behind
/// the user's finger. The button and the switch are the retry.
final FutureProviderFamily<MatchResult, MatchQuery> matchResultsProvider =
    FutureProvider.family<MatchResult, MatchQuery>(
      (ref, query) => ref
          .watch(matchingRepositoryProvider)
          .suggestions(
            courseUnitId: query.courseUnitId,
            widenToSubject: query.widenToSubject,
          ),
      retry: (retryCount, error) => null,
    );

/// What a student has done about one course unit.
///
/// A family keyed by the unit, so choosing a tutor in `CSC 121` and then going
/// back to ask about `MAT 221` are two independent answers rather than one slot
/// each overwriting the other. A plain `Notifier` rather than an `AsyncNotifier`
/// because there is nothing to load: the state starts as "no request yet" and the
/// only transitions are ones the student causes.
final NotifierProviderFamily<TutorChoiceController, TutorChoice, String>
tutorChoiceProvider =
    NotifierProvider.family<TutorChoiceController, TutorChoice, String>(
      TutorChoiceController.new,
    );

class TutorChoiceController extends Notifier<TutorChoice> {
  TutorChoiceController(this.courseUnitId);

  /// The unit being chosen for, as a public id.
  final String courseUnitId;

  MatchingRepository get _repository => ref.read(matchingRepositoryProvider);

  @override
  TutorChoice build() => const TutorChoice();

  /// Asks for help with [topic] and names [candidateTutorId] to take it.
  ///
  /// Two calls, in that order, and the screen shows what each one means: a
  /// request exists the moment this returns, and a tutor has been asked only when
  /// the second does. Reporting success after the first would tell a student
  /// their choice was sent when nothing had been sent to anybody, and reporting
  /// failure after the second would be a lie about a request that really does
  /// exist.
  ///
  /// Returns whether a tutor was named, so the caller can decide between the
  /// waiting state and leaving the student on the list with the reason it failed.
  Future<bool> chooseTutor({
    required String topic,
    required String candidateTutorId,
    required String tutorName,
    String? description,
  }) async {
    if (state.submitting) return false;
    state = state.copyWith(submitting: true, clearFailure: true);

    final HelpRequest request;
    try {
      request = await _repository.createHelpRequest(
        courseUnitId: courseUnitId,
        topic: topic,
        description: description,
      );
    } on Object catch (error) {
      if (!ref.mounted) return false;
      state = state.copyWith(
        tutorName: tutorName,
        submitting: false,
        failure: failureFor(error),
      );
      return false;
    }

    if (!ref.mounted) return false;
    state = state.copyWith(request: request);

    try {
      final chosen = await _repository.selectTutor(
        requestId: request.id,
        candidateTutorId: candidateTutorId,
      );
      if (!ref.mounted) return false;
      state = state.copyWith(request: chosen, submitting: false);
      return true;
    } on Object catch (error) {
      if (!ref.mounted) return false;
      // The request stands and is kept in state. Throwing it away would lose the
      // fact that the student has asked for help, and leave them on a list
      // suggesting they had not started.
      state = state.copyWith(
        tutorName: tutorName,
        submitting: false,
        failure: failureFor(error),
      );
      return false;
    }
  }

  /// Re-reads what the API holds for the request this student already made.
  ///
  /// For the waiting state, and the reason it exists is that this state can become
  /// false without anything on this device happening: a tutor can decline, or
  /// confirm, while the student is looking at "not yet confirmed". The API is the
  /// only party that knows, so the student has to ask it.
  ///
  /// The whole list is fetched rather than one request because that is the only
  /// endpoint there is for a student's own requests, and because picking the one
  /// out of it by id is the same work as the API's own filter would be.
  Future<void> refreshRequest() async {
    final existing = state.request;
    if (existing == null || state.refreshing) return;
    state = state.copyWith(refreshing: true, clearFailure: true);

    try {
      final mine = await _repository.myHelpRequests();
      if (!ref.mounted) return;
      for (final request in mine) {
        if (request.id == existing.id) {
          state = state.copyWith(refreshing: false, request: request);
          return;
        }
      }
      // The request is gone from the list the API returns. Not proof of anything
      // -- it was there a moment ago -- so the last known state is kept rather
      // than replaced by an assumption, and the screen keeps saying what it was
      // last told.
      state = state.copyWith(refreshing: false);
    } on Object catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(refreshing: false, failure: failureFor(error));
    }
  }
}

/// The student's own progress through choosing a tutor for one unit.
///
/// [request] is the request as the API last reported it, not a local guess at
/// what became of it: `PENDING_CONFIRMATION` is not a booking, and a client that
/// promoted it to one would be promising a session nobody has agreed to. A
/// student's screen that wants to know whether a tutor has answered has to be
/// told by the API, and this is what it was last told.
@immutable
class TutorChoice {
  const TutorChoice({
    this.request,
    this.tutorName,
    this.submitting = false,
    this.refreshing = false,
    this.failure,
  });

  /// The request this student made for the unit, or null if they have not made
  /// one in this session.
  final HelpRequest? request;

  /// The tutor the student last tried to name, or null before they have tried.
  ///
  /// Kept because the failure message needs it: "the request was not sent, so
  /// *this* tutor was not asked" is the sentence that stops a student retrying
  /// somewhere else, and the controller is the only party that knows which tutor
  /// the attempt was for. Cleared with the failure rather than kept forever, so a
  /// stale name cannot be attached to a later, unrelated failure.
  final String? tutorName;

  /// Whether a create-or-select is in flight.
  ///
  /// The button is disabled on it rather than the tile being removed: a student
  /// who cannot see which tutor they were choosing cannot tell a slow network
  /// from a refused tap.
  final bool submitting;

  /// Whether a re-read is in flight.
  final bool refreshing;

  /// Why the last attempt failed, or null.
  ///
  /// Held on the choice rather than on the results, because the two are different
  /// questions: the list may have loaded perfectly well and the request still
  /// have been refused.
  final Failure? failure;

  /// Whether a tutor has been named and has not answered.
  ///
  /// False when nothing has been chosen, and false when the API has not been asked
  /// since: [request] being present is not the same as its status being known.
  bool get isAwaitingTutor => request?.isAwaitingTutor ?? false;

  /// Whether the chosen tutor has said no.
  bool get isDeclined => request?.isDeclined ?? false;

  /// Whether a request exists, whichever state it is in.
  bool get hasRequest => request != null;

  TutorChoice copyWith({
    HelpRequest? request,
    String? tutorName,
    bool? submitting,
    bool? refreshing,
    Failure? failure,
    bool clearFailure = false,
  }) {
    return TutorChoice(
      request: request ?? this.request,
      tutorName: clearFailure ? null : (tutorName ?? this.tutorName),
      submitting: submitting ?? this.submitting,
      refreshing: refreshing ?? this.refreshing,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TutorChoice &&
          other.request == request &&
          other.tutorName == tutorName &&
          other.submitting == submitting &&
          other.refreshing == refreshing &&
          other.failure == failure;

  @override
  int get hashCode =>
      Object.hash(request, tutorName, submitting, refreshing, failure);
}

/// The requests that named the signed-in tutor and are waiting on their answer.
///
/// The tutor's half of the choice, and the only place a tutor learns they were
/// chosen: without it a student waits on a decision nobody was ever shown.
///
/// An [AsyncNotifier] because the only thing to do with the list is load it, and
/// [AsyncValue] already carries the three states this screen renders. The retry
/// is off for the reason it is off everywhere else here: the screen has a button,
/// and that button is the retry.
///
/// Not keyed by anything, because the set is the tutor's own outstanding work and
/// there is only ever one answer to it. [TutorDecisionController] is the only
/// thing that changes it.
final tutorRequestsProvider =
    AsyncNotifierProvider<TutorRequestsNotifier, List<HelpRequest>>(
      TutorRequestsNotifier.new,
      retry: (retryCount, error) => null,
    );

class TutorRequestsNotifier extends AsyncNotifier<List<HelpRequest>> {
  @override
  Future<List<HelpRequest>> build() {
    return ref.read(matchingRepositoryProvider).requestsAwaitingMe();
  }
}

/// One tutor's answer to one request, and whether that answer was given.
///
/// A family keyed by request id so two rows cannot overwrite each other's state:
/// a tutor with two outstanding requests who declines the first must not see the
/// second row light up as answered. A single controller holding a set would make
/// that a field to keep consistent, and there is no version of it that is simpler
/// than one value per request.
///
/// A plain [Notifier] and not an [AsyncNotifier] because there is nothing to
/// load. The list belongs to [tutorRequestsProvider] and this only records what
/// was decided about a row of it.
final NotifierProviderFamily<TutorDecisionController, TutorDecision, String>
tutorDecisionProvider =
    NotifierProvider.family<TutorDecisionController, TutorDecision, String>(
      TutorDecisionController.new,
    );

class TutorDecisionController extends Notifier<TutorDecision> {
  TutorDecisionController(this.requestId);

  /// The request this answer is about, as a public id.
  final String requestId;

  MatchingRepository get _repository => ref.read(matchingRepositoryProvider);

  @override
  TutorDecision build() => const TutorDecision();

  /// Turns the request down, returning whether it was declined.
  Future<bool> decline() async {
    if (state.submitting) return false;
    state = state.copyWith(submitting: true, clearFailure: true);

    try {
      final declined = await _repository.declineHelpRequest(
        requestId: requestId,
      );
      if (!ref.mounted) return false;
      state = state.copyWith(declined: declined, submitting: false);
      // The row is gone from the API's answer, so leaving the list alone would
      // show a tutor a decision they have already made until they pulled to
      // refresh.
      ref.invalidate(tutorRequestsProvider);
      return true;
    } on Object catch (error) {
      if (!ref.mounted) return false;
      state = state.copyWith(submitting: false, failure: failureFor(error));
      return false;
    }
  }
}

/// A tutor's decision about one request.
///
/// [declined] is the request as the API returned it, which is what lets the row
/// say something true for the moment before the list refreshes rather than a
/// spinner with no outcome in it.
@immutable
class TutorDecision {
  const TutorDecision({this.declined, this.submitting = false, this.failure});

  /// The request as it now stands, once declined.
  final HelpRequest? declined;

  /// Whether the answer is in flight.
  final bool submitting;

  /// Why the answer failed, or null.
  final Failure? failure;

  TutorDecision copyWith({
    HelpRequest? declined,
    bool? submitting,
    Failure? failure,
    bool clearFailure = false,
  }) {
    return TutorDecision(
      declined: declined ?? this.declined,
      submitting: submitting ?? this.submitting,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TutorDecision &&
          other.declined == declined &&
          other.submitting == submitting &&
          other.failure == failure;

  @override
  int get hashCode => Object.hash(declined, submitting, failure);
}
