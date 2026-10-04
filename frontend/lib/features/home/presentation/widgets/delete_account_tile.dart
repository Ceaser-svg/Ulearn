import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/widgets/content_width_limiter.dart';
import 'package:peerpass/features/home/presentation/providers/delete_account_controller.dart';

/// The account row that erases the signed-in user's account.
///
/// Not on the home screen itself. It is the one control on this app that cannot be
/// undone, and putting it two taps from the landing screen would make a mis-tap
/// permanent. A student who wants it should have to have meant it.
///
/// The confirmation asks the user to re-enter the account email. This makes the
/// irreversible action explicit while remaining usable for every account.
class DeleteAccountTile extends ConsumerStatefulWidget {
  const DeleteAccountTile({super.key});

  @override
  ConsumerState<DeleteAccountTile> createState() => _DeleteAccountTileState();
}

class _DeleteAccountTileState extends ConsumerState<DeleteAccountTile> {
  /// True between confirming and the request resolving, so the row cannot be
  /// invoked twice. The server is idempotent, but a second tap mid-flight is a
  /// second spinner and a confusing screen rather than an error.
  bool _busy = false;

  /// Set only when the request failed. A failure here is worth showing: the
  /// account is very likely still there, and the user asked for something that
  /// did not happen.
  String? _problem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _busy;
    final email = ref.watch(sessionControllerProvider).profile?.email;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          // A destructive control, so it is not the same filled button that
          // carries every other affirmative action on this screen.
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
          onPressed: busy || email == null ? null : () => _confirm(email),
          icon: busy
              ? const SizedBox(
                  height: AppDimens.sm,
                  width: AppDimens.sm,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_outline_rounded),
          label: const Text('Delete my account'),
        ),
        if (_problem != null) ...[
          const SizedBox(height: AppDimens.sm),
          // Not a `FailureView`: this sits inside a populated screen rather than
          // standing in for one, and the rest of the screen is still usable.
          Text(
            _problem!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _confirm(String email) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _DeleteAccountDialog(email: email),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _problem = null;
    });

    try {
      await ref.read(deleteAccountControllerProvider)();
      // No success message. The controller ends the session, so the router
      // replaces this screen with the sign-in one, and anything printed here
      // would never be seen.
    } on Failure catch (failure) {
      if (!mounted) return;
      setState(() => _problem = _describe(failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Says what happened, in the user's terms.
  ///
  /// The network case is not distinguished from the others on purpose. Telling
  /// the user their account "may or may not have been deleted" is both unusable
  /// and not true: the request that failed did not arrive, so the account is
  /// intact and they can simply sign in and try again. What matters is that they
  /// know it did not happen.
  static String _describe(Failure failure) {
    return switch (failure) {
      NetworkFailure() =>
        'Could not reach the server, so your account is unchanged. '
            'Check your connection and try again.',
      AuthFailure() =>
        'Your session had already ended, so nothing was deleted. '
            'Sign in again to finish.',
      ValidationFailure() =>
        'The server rejected the request, so your account is unchanged.',
      ServerFailure() =>
        'The server could not delete the account: ${failure.message}',
      _ => 'Your account could not be deleted. Nothing was changed.',
    };
  }
}

/// The email-to-confirm gate.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.email});

  final String email;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final TextEditingController _typed = TextEditingController();
  bool _matches = false;

  @override
  void initState() {
    super.initState();
    // Rebuilds on every keystroke, because the button's enabled state *is* the
    // confirmation. Watching the controller rather than validating on submit
    // means the user can see the button come alive as they finish the word.
    _typed.addListener(() {
      final matches =
          _typed.text.trim().toLowerCase() == widget.email.toLowerCase();
      if (matches != _matches) setState(() => _matches = matches);
    });
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Delete your account?'),
      content: ContentWidthLimiter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your name, email and academic details are erased. '
              'Sessions and ratings you were part of are kept, because other '
              "people's tutor standing is calculated from them.",
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppDimens.md),
            Text(
              'Type your email address to confirm: ${widget.email}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppDimens.sm),
            TextField(
              controller: _typed,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Email address'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep my account'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          // Disabled until the word matches, which is the whole mechanism. There
          // is deliberately no way to enable it from code.
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Delete permanently'),
        ),
      ],
    );
  }
}
