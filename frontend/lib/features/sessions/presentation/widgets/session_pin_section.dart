import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/features/sessions/data/models/session_model.dart';
import 'package:peerpass/features/sessions/data/repositories/sessions_repository.dart';
import 'package:peerpass/features/sessions/presentation/providers/session_providers.dart';

/// The two-digit handshake that starts a session in person.
///
/// The tutor reveals the digits and the tutee enters them. It was the other way
/// round, which made the handshake prove nothing: the student held the answer on
/// their own screen, and the tutor typed what they were shown. Worse, the API put
/// the pin in a payload both parties could read, so the tutee could skip the tutor
/// entirely.
///
/// Both halves live in one file because they are one flow -- a tutor reading two
/// digits aloud and a student typing them -- and splitting them would have meant
/// either two screens or a screen guessing which one to be.
///
/// The PIN is never generated here, and this side counts no attempts or locks
/// anybody out. Both are the API's: a lock a device enforces is one a student
/// clears by reinstalling the app.
class SessionPinSection extends ConsumerStatefulWidget {
  const SessionPinSection({
    required this.session,
    required this.viewerId,
    super.key,
  });

  final SessionModel session;

  /// The signed-in user's public id, which decides which half of the handshake
  /// this reader is standing on.
  ///
  /// Nullable because the profile loads on its own schedule and a session can be
  /// on screen before it arrives. A null id renders nothing rather than guessing a
  /// side: showing the wrong half is worse than showing none until the profile
  /// lands.
  final String? viewerId;

  @override
  ConsumerState<SessionPinSection> createState() => _SessionPinSectionState();
}

class _SessionPinSectionState extends ConsumerState<SessionPinSection> {
  final _pin = TextEditingController();

  /// The pin the API returned, fetched when the tutor asks to see it.
  ///
  /// Not read off [SessionModel], which no longer carries one. A field there would
  /// be readable by the tutee too, and a tutee holding their own PIN is a
  /// handshake nobody has to take part in.
  SessionPinModel? _pin_;

  /// Set when the pin could not be fetched, so the panel can say so rather than
  /// offering a reveal that silently does nothing.
  bool _revealFailed = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final state = ref.watch(sessionDetailProvider(session.id));

    final content = switch (session.status) {
      TutoringSessionStatus.scheduled => switch (widget.viewerId) {
        // Reversed from the original: the tutor reveals, the tutee enters.
        final viewerId? when session.isTutor(viewerId) => _reveal(context),
        final viewerId? when session.isTutee(viewerId) => _enter(context, state),
        _ => null,
      },
      // Once the session is live the handshake has done its job, and the pin is
      // no longer the thing either party needs to see.
      TutoringSessionStatus.inProgress => _started(),
      _ => null,
    };

    // A status that has no handshake -- completed, cancelled, a no-show, or one
    // this client does not recognise -- renders nothing rather than an empty card.
    if (content == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.lg),
        child: content,
      ),
    );
  }

  /// The tutor's half: the digits to read out.
  Widget _reveal(BuildContext context) {
    final theme = Theme.of(context);
    final pin = _pin_;

    if (_revealFailed) {
      return const _Panel(
        icon: Icons.cloud_off_outlined,
        title: 'PIN unavailable',
        body:
            'The handshake PIN could not be loaded. Check your connection and '
            'try again.',
      );
    }

    if (pin == null) {
      return _Panel(
        icon: Icons.visibility_outlined,
        title: 'Your handshake PIN',
        body:
            'Read these two digits to your student. They enter them on their '
            'side and the session starts.',
        trailing: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _fetchPin,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Show PIN'),
          ),
        ),
      );
    }

    return _Panel(
      icon: Icons.pin_outlined,
      title: 'Your handshake PIN',
      body:
          'Read these two digits to your student. They enter them on their side '
          'and the session starts.',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            pin.sessionPin,
            style: theme.textTheme.headlineMedium?.copyWith(
              // Tabular figures so two digits do not shift as they are read
              // aloud, which is the one thing this value is for.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          // Advisory only. The lockout is the API's; this is here so a tutor can
          // stop the tutee guessing rather than let them burn every attempt in a
          // room where they are trying to learn.
          if (pin.attemptsRemaining <= 2) ...[
            const SizedBox(height: AppDimens.xs),
            Text(
              pin.attemptsRemaining == 0
                  ? 'Your student has used every attempt. They will have to wait '
                        'before trying again.'
                  : 'Your student has ${pin.attemptsRemaining} attempt'
                        '${pin.attemptsRemaining == 1 ? '' : 's'} left.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppDimens.xs),
          TextButton(
            // Clears the pin rather than flipping a local flag: nothing is held
            // once the tutor has read it, so the value does not outlive its use
            // on a phone lying face up on a table.
            onPressed: () => setState(() => _pin_ = null),
            child: const Text('Hide PIN'),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchPin() async {
    final repo = ref.read(sessionsRepositoryProvider);
    try {
      final pin = await repo.revealPin(sessionId: widget.session.id);
      if (!mounted) return;
      setState(() {
        _pin_ = pin;
        _revealFailed = false;
      });
    } on Failure {
      // Deliberately not showing the API's text: a failed reveal is a transport
      // problem, and the retry is the same either way.
      if (!mounted) return;
      setState(() => _revealFailed = true);
    }
  }

  /// The tutee's half: the digits the tutor just read out.
  Widget _enter(BuildContext context, SessionDetailState state) {
    final theme = Theme.of(context);
    final submitting = state.submitting;

    // Two digits is the shape the API documents, so the input refuses anything
    // else before a request is made. This is not the handshake rule -- whether
    // the digits are *right* is still the API's call -- only the shape of the
    // field.
    final readyToSubmit = _pin.text.length == 2 && !submitting;

    return _Panel(
      icon: Icons.dialpad_outlined,
      title: 'Enter the handshake PIN',
      body:
          'Your tutor is reading you two digits. Enter them here and the session '
          'starts.',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _pin,
            enabled: !submitting,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 2,
            // Not a const list: `digitsOnly` is a static field rather than a
            // constructor, and the length limiter carries a value.
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            decoration: InputDecoration(
              labelText: 'PIN',
              hintText: 'e.g. 42',
              counterText: '',
              errorText: state.pinRejected ? _wrongPin : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: readyToSubmit ? (_) => _submit() : null,
          ),
          const SizedBox(height: AppDimens.md),
          FilledButton(
            onPressed: readyToSubmit ? _submit : null,
            child: submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start session'),
          ),
          if (state.actionFailure != null && !state.pinRejected) ...[
            const SizedBox(height: AppDimens.md),
            Text(
              state.actionFailure!.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _started() => const _Panel(
    icon: Icons.play_circle_outline,
    title: 'Handshake complete',
    body: 'The PIN was accepted and this session is live.',
  );

  Future<void> _submit() async {
    final started = await ref
        .read(sessionDetailProvider(widget.session.id).notifier)
        .submitPin(_pin.text);
    // Cleared either way. On success the field is gone with the whole panel; on
    // refusal the digits should not still be in the box for the next attempt.
    if (!mounted) return;
    _pin.clear();
    if (started) setState(() {});
  }
}

/// The wording for a refused PIN.
///
/// Written here rather than taken from the API's `detail`, even though that text
/// is safe to show. The server's sentence is written for a log; this one is
/// written for a tutor standing in front of a student, and it says what to do next
/// rather than only what went wrong. The API's own message is still available
/// through [SessionDetailState.actionFailure] for a client that wants it.
const String _wrongPin =
    'That is not the right PIN. Ask your tutor to check it.';

/// The frame both halves of the handshake share.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.body,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppDimens.sm),
            Expanded(
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: AppDimens.xs),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (trailing case final widget?) ...[
          const SizedBox(height: AppDimens.lg),
          widget,
        ],
      ],
    );
  }
}
