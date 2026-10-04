import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit.dart';
import 'package:peerpass/features/matching/data/models/help_request.dart';
import 'package:peerpass/features/matching/data/models/match_result.dart';

/// The matching contract the screens depend on.
///
/// Every method throws a [Failure], never a transport exception and never a
/// `FormatException`. Translating `DioException`, problem documents, and
/// unparseable bodies into [Failure] happens in the implementation, so a screen
/// renders a message and never has to know whether the API answered with a socket
/// error, a 422, or a body that was not the shape it documents.
///
/// Now holding help requests as well, because a request is how a student asks to
/// be matched: without [createHelpRequest] and [selectTutor] the list this feature
/// shows is a list nobody can act on.
///
/// Narrow on purpose in one direction. Confirming -- the tutor accepting, which
/// creates a session -- is not here. A session belongs to the sessions feature and
/// its repository owns creating one, so a confirm from this side would be two
/// features writing one endpoint and two answers to "who may confirm this".
abstract interface class MatchingRepository {
  /// The course units this student may pick, for their own university.
  ///
  /// Reference data, read to fill the picker. The API answers a university it does
  /// not have with an empty list rather than a 404, which is what lets a picker
  /// filtered on a stale value show nothing instead of failing.
  Future<List<CourseUnit>> courseUnits({
    String? universityId,
    String? subjectId,
  });

  /// Who may take this course unit, in the API's ranking.
  ///
  /// [widenToSubject] is the one search behaviour a client may request and it is
  /// opt-in, because widening by default would return tutors who cannot help with
  /// the course the student asked about. When it is asked for and the exact unit
  /// has nobody, the answer says so in [MatchResult.widened] rather than
  /// returning a wider list as though it were the answer to this question.
  ///
  /// "Nobody at all" is a [MatchResult] with
  /// [MatchResult.noEligibleTutors] set, not a failure. A student whose unit has
  /// no eligible tutor has been told something true and actionable, and
  /// rendering that as an error would be a lie about the platform.
  Future<MatchResult> suggestions({
    required String courseUnitId,
    bool widenToSubject = false,
    int? limit,
  });

  /// The requests this student created.
  ///
  /// The only source a student's screen has for what became of a request it made,
  /// because the matching response says who is eligible and nothing about a
  /// request's fate. A screen that has to show "your tutor declined" is reading
  /// it from here.
  Future<List<HelpRequest>> myHelpRequests();

  /// Asks for help with a course unit, and returns the request as it now stands.
  ///
  /// A new request each time, and never a reused one. Reusing would be invisible
  /// to the student and would attach a second question to a thread a tutor had
  /// already answered, which is exactly the record MVP decision 3 is trying to
  /// keep legible.
  ///
  /// [topic] is the specific question, not the course name, and is required by
  /// the API because a tutor agreeing to a request needs the second thing rather
  /// than the first.
  Future<HelpRequest> createHelpRequest({
    required String courseUnitId,
    required String topic,
    String? description,
  });

  /// Names the tutor a request should wait on, and returns the request as it now
  /// stands.
  ///
  /// Returns a request in [HelpRequestStatus.pendingConfirmation], which is not
  /// the same as a booking: nobody has agreed to anything yet, and a screen that
  /// said "booked" here would be promising the student something the tutor may
  /// still decline.
  ///
  /// The API re-derives the eligible candidates for this request's own unit and
  /// refuses a tutor who is not among them, so [candidateTutorId] being an id
  /// this client once held is no guarantee of anything. That refusal arrives as a
  /// [ValidationFailure] with a `candidate_tutor_id` field error, which a screen
  /// can render next to the tile the student tapped.
  Future<HelpRequest> selectTutor({
    required String requestId,
    required String candidateTutorId,
  });

  /// The requests that named the signed-in tutor and are waiting on their answer.
  ///
  /// Empty for anyone who has not been named, including a student, which is
  /// deliberate: a refusal would put a permission error on a screen that simply
  /// has nothing to show.
  Future<List<HelpRequest>> requestsAwaitingMe();

  /// Turns down a request that is waiting on the signed-in tutor.
  ///
  /// The request comes back declined rather than removed, so the student can see
  /// that it was answered. It stays declined: a second refusal of the same
  /// request arrives as a [ConflictFailure], and the student's way forward is a
  /// new request rather than reopening this one.
  Future<HelpRequest> declineHelpRequest({required String requestId});
}

/// The matching contract, as a live instance.
///
/// Declared in the contract file rather than beside the matching screens, for
/// the same reason `sessionsRepositoryProvider` is: this is the handle by which
/// another feature would reach this feature, and a provider living in
/// `presentation/` could not be imported without dragging the screens along.
///
/// Throwing rather than defaulting keeps a missing override loud. A silent fake
/// default would let a build ship with a picker that finds no tutors and a
/// results screen that says nobody is eligible -- two very different claims from
/// one missing line in the composition root.
final matchingRepositoryProvider = Provider<MatchingRepository>(
  (ref) => throw UnimplementedError(
    'matchingRepositoryProvider must be overridden in ProviderScope.',
  ),
);
