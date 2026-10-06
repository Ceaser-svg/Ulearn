import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/widgets/content_width_limiter.dart';
import 'package:peerpass/core/widgets/failure_view.dart';
import 'package:peerpass/core/widgets/loading_view.dart';
import 'package:peerpass/features/sessions/data/models/rating_model.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/presentation/formatting.dart';
import 'package:peerpass/features/sessions/presentation/providers/session_providers.dart';
import 'package:peerpass/features/sessions/presentation/widgets/meeting_link_field.dart';
import 'package:peerpass/features/sessions/presentation/widgets/session_pin_section.dart';
import 'package:peerpass/features/sessions/presentation/widgets/session_status_chip.dart';

/// One session, and the one thing the reader can do to it right now.
///
/// The action offered is a function of the status, and only of the status: a
/// scheduled session has the handshake, a live one can be ended, a completed one
/// can be rated. The transitions themselves are the API's -- this screen asks for
/// a move and renders whatever comes back, including a refusal -- so there is no
/// second state machine here to fall out of step with the server's.
///
/// A completed session must be rated by the student before this quality loop is
/// complete. `POST /v1/ratings/{session_id}` is a separate request, so this
/// screen keeps the completed session visible and sends the student to the
/// required form instead of treating the rating as optional.
class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionDetailProvider(sessionId));
    final session = state.session;

    if (session == null) {
      // A load that failed records why, and a load still in flight has not. The
      // order matters: an error has to win over a spinner, or a student who
      // cannot reach the API watches one forever.
      final failure = state.loadFailure;
      if (failure != null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Session')),
          body: SafeArea(
            child: Center(
              child: ContentWidthLimiter(
                child: FailureView(
                  failure: failure,
                  onRetry: () =>
                      ref.read(sessionDetailProvider(sessionId).notifier).reload(),
                ),
              ),
            ),
          ),
        );
      }
      return const Scaffold(
        body: SafeArea(child: Center(child: LoadingView())),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ContentWidthLimiter(
              child: Padding(
                padding: const EdgeInsets.all(AppDimens.lg),
                child: _Body(session: session, state: state),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The session's record, and the action its status allows.
class _Body extends ConsumerWidget {
  const _Body({required this.session, required this.state});

  final SessionModel session;
  final SessionDetailState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Who the reader is, which is what decides which half of the handshake they
    // are shown and whether a rating is of a tutor or of a student. The session
    // names both parties and the API has already refused anyone who is neither.
    final viewerId = ref.watch(sessionControllerProvider).profile?.publicId;
    final link = session.meetingLink;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(session.topic, style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppDimens.sm),
        Row(
          children: [
            SessionStatusChip(session: session),
            const SizedBox(width: AppDimens.sm),
            Expanded(
              child: Text(
                sessionWhenLabel(session),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.lg),
        _FactRow(label: 'Course unit', value: session.courseUnitLabel),
        _FactRow(
          label: _otherPartyLabel(session, viewerId),
          value: _otherParty(session, viewerId),
        ),
        _FactRow(label: 'Length', value: durationLabel(session.durationMinutes)),
        if (session.startedAt case final startedAt?)
          _FactRow(label: 'Started', value: momentLabel(startedAt)),
        if (session.endedAt case final endedAt?)
          _FactRow(label: 'Ended', value: momentLabel(endedAt)),
        if (link != null) ...[
          const SizedBox(height: AppDimens.lg),
          MeetingLinkField(link: link),
        ],
        const SizedBox(height: AppDimens.lg),
        SessionPinSection(session: session, viewerId: viewerId),
        if (state.actionFailure != null && !state.pinRejected) ...[
          const SizedBox(height: AppDimens.md),
          Text(
            state.actionFailure!.message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: AppDimens.lg),
        _Action(session: session, state: state, viewerId: viewerId),
      ],
    );
  }

  /// What the other party is called on this screen.
  ///
  /// Named after the side of the session rather than after the role, so a tutor
  /// and a student read the same row the same way: whoever is on the other end of
  /// it is the one they are about to meet.
  String _otherPartyLabel(SessionModel session, String? viewerId) {
    if (viewerId != null && session.isTutee(viewerId)) return 'Tutor';
    if (viewerId != null && session.isTutor(viewerId)) return 'Student';
    return 'Other participant';
  }

  /// Who the other party is, by name.
  ///
  /// Falls back to the public id when the name is missing, for the same reason
  /// the unit fallback exists: this row is about identifying a person the reader
  /// is about to meet, and an empty row would answer nothing at all. Once the
  /// other account sets a name -- which onboarding asks for -- the name is what
  /// appears.
  String _otherParty(SessionModel session, String? viewerId) {
    if (viewerId == null) return 'Not available';
    final name = session.otherPartyName(viewerId);
    if (name != null && name.trim().isNotEmpty) return name;
    return session.otherPartyId(viewerId) ?? 'Not available';
  }
}

/// The primary action, chosen by the status and nothing else.
class _Action extends StatelessWidget {
  const _Action({
    required this.session,
    required this.state,
    required this.viewerId,
  });

  final SessionModel session;
  final SessionDetailState state;

  /// Null when the app does not know who is signed in, which the router does not
  /// allow; the endorsement is then left out rather than guessed at.
  final String? viewerId;

  @override
  Widget build(BuildContext context) {
    // A rating this client just submitted outranks the `is_rated` flag: the flag
    // says a rating exists for the session, which is not the same claim as "you
    // gave one", and on a tutor's screen it is the other party's rating.
    final given = state.ratingGiven;
    if (given != null) return _RatingReadOnly(rating: given);
    if (session.isRated) return const _RatedBySomeoneElse();

    return switch (session.status) {
      // The handshake in `SessionPinSection` is the action for a scheduled
      // session, and it renders nothing for a reader who is neither party.
      TutoringSessionStatus.scheduled => const SizedBox.shrink(),
      TutoringSessionStatus.inProgress => _EndSession(session: session, state: state),
      TutoringSessionStatus.completed => _RateThisSession(session: session),
      // Nothing to offer for a session that did not happen. A no-show is the
      // case where a rating might be tempting and must not be: the API refuses it,
      // and the tutor attending a session the student missed is not something a
      // rating form is for.
      TutoringSessionStatus.cancelled ||
      TutoringSessionStatus.noShow ||
      null => Text(
        'This session did not take place, so there is nothing to do here.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    };
  }
}

/// Ending a live session.
///
/// Confirmed before it is sent. A completed session is terminal in the API's
/// transition table, so the button is the only moment at which a student can see
/// what they are about to give up -- the ability to correct a session that ended
/// early, and the hours that were recorded against it.
class _EndSession extends ConsumerWidget {
  const _EndSession({required this.session, required this.state});

  final SessionModel session;
  final SessionDetailState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: state.submitting ? null : () => _confirm(context, ref),
      child: state.submitting
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('End session'),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End this session?'),
        content: const Text(
          'The time so far is recorded against this session and it cannot be '
          'reopened.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(sessionDetailProvider(session.id).notifier).endSession();
  }
}

/// The affordance that opens the rating screen.
class _RateThisSession extends StatelessWidget {
  const _RateThisSession({required this.session});

  final SessionModel session;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => context.push(AppRoutes.rateSessionPath(session.id)),
      icon: const Icon(Icons.star_outline_rounded),
      label: const Text('Rate this session'),
    );
  }
}

/// The score this client gave, shown back and not editable.
///
/// Read-only because `POST /v1/ratings/{session_id}` updates an existing rating in
/// place, and a screen that looked editable would be a promise the detail screen
/// does not keep: there is no route to change a rating, only to submit one, and
/// the only way to change your mind today is to open the rating screen again.
class _RatingReadOnly extends StatelessWidget {
  const _RatingReadOnly({required this.rating});

  final RatingModel rating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star_rounded),
                const SizedBox(width: AppDimens.sm),
                Expanded(
                  child: Text(
                    'You rated this ${rating.scoreLabel}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (rating.feedbackText case final note?) ...[
              const SizedBox(height: AppDimens.sm),
              Text(note, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}

/// A session that carries a rating this client did not give.
///
/// Says exactly that. `is_rated` is true for both parties of a rated session, so
/// telling a tutor they have rated their own session would be a lie, and telling
/// a student their rating was recorded without showing it would be the other kind
/// -- the score is not in any response the client can read.
class _RatedBySomeoneElse extends StatelessWidget {
  const _RatedBySomeoneElse();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(
          Icons.check_circle_outline,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppDimens.sm),
        Expanded(
          child: Text(
            'This session has been rated.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// A label and its value, in a record rather than a form.
class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
