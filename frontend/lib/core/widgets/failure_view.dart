import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';

/// Renders a [Failure] as something a student can act on.
///
/// Exists so no screen has to decide that a `NetworkFailure` deserves different
/// wording from a `ServerFailure`, and so the whole app fails the same way. The
/// pattern is an exhaustive switch, which means adding a failure type will not
/// compile until it has been given a presentation somewhere.
class FailureView extends StatelessWidget {
  const FailureView({required this.failure, this.onRetry, super.key});

  final Failure failure;

  /// Omitted when the operation cannot usefully be retried, such as a validation
  /// rejection, which will fail identically until the input changes.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (failure case final ThrottledFailure throttle) {
      return _ThrottledNotice(throttle: throttle, onRetry: onRetry);
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(context), size: 40, color: theme.colorScheme.error),
            const SizedBox(height: AppDimens.md),
            Text(
              failure.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppDimens.lg),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _icon(BuildContext context) {
    return switch (failure) {
      NetworkFailure() => Icons.wifi_off_rounded,
      AuthFailure() => Icons.lock_outline_rounded,
      ValidationFailure() => Icons.edit_note_rounded,
      NotFoundFailure() => Icons.search_off_rounded,
      ConflictFailure() => Icons.sync_problem_rounded,
      ThrottledFailure() => Icons.hourglass_top_rounded,
      ServerFailure() => Icons.cloud_off_rounded,
      CancelledFailure() => Icons.block_rounded,
      UnknownFailure() => Icons.error_outline_rounded,
    };
  }
}

/// A lockout, counting down to the moment retrying could work.
///
/// The countdown is the point. A retry button offered during a lockout invites a
/// student to spend their remaining budget discovering that the API said no --
/// and on the sign-in path every attempt during the window is another hash the
/// server throws away, so a button that looks harmless is the one thing that
/// makes a lockout worse.
///
/// Ticks once a second rather than to the exact expiry: the last second is not
/// worth a rebuild, and the button appears on the first tick at or after zero.
class _ThrottledNotice extends StatefulWidget {
  const _ThrottledNotice({required this.throttle, this.onRetry});

  final ThrottledFailure throttle;
  final VoidCallback? onRetry;

  @override
  State<_ThrottledNotice> createState() => _ThrottledNoticeState();
}

class _ThrottledNoticeState extends State<_ThrottledNotice> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_ThrottledNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.throttle.retryAt != widget.throttle.retryAt) {
      _ticker?.cancel();
      _start();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() {
    if (widget.throttle.isWaitOver) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.throttle.isWaitOver) {
        _ticker?.cancel();
        _ticker = null;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = widget.throttle.isWaitOver
        ? Duration.zero
        : widget.throttle.retryAt!.difference(clock.now());

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_top_rounded,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: AppDimens.md),
            Text(
              widget.throttle.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: AppDimens.sm),
            Text(
              _clock(remaining),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (widget.onRetry != null && widget.throttle.isWaitOver) ...[
              const SizedBox(height: AppDimens.lg),
              FilledButton.tonal(
                onPressed: widget.onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A clock, not a duration: `m:ss` reads as time passing at a glance, where
  /// "14 minutes" is a number to do arithmetic on.
  String _clock(Duration remaining) {
    if (remaining.inSeconds <= 0) return 'You can try again now.';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
