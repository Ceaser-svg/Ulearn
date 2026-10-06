import 'package:flutter/material.dart';

/// What every admin list shows while it is loading.
///
/// A shared view so that "loading" looks and reads the same on all five screens.
/// The wording says what is happening, because a spinner on its own leaves an
/// operator unsure whether the console is working or has hung.
class AdminLoadingView extends StatelessWidget {
  const AdminLoadingView({this.what = 'records', super.key});

  /// What is being loaded, in a phrase that follows "Loading the ".
  final String what;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            'Loading the $what.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// What every admin list shows when a read failed.
///
/// Says the read failed rather than that the screen is broken, and offers the
/// one action that can help. It does not render the error: a list read that
/// fails on the network can carry a URL or a host, and an operator has no use
/// for either.
class AdminLoadFailedView extends StatelessWidget {
  const AdminLoadFailedView({required this.onRetry, super.key});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not load this view.'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// What every admin list shows when a read succeeded and matched nothing.
///
/// [emptyMessage] is a parameter because "nothing here" is a different fact
/// depending on why: a queue nobody has submitted to is a quiet pilot, whereas a
/// filtered queue with nothing in it means the operator has just worked it to
/// empty. Telling an operator their filter is empty is the whole point of
/// letting them set one.
class AdminEmptyView extends StatelessWidget {
  const AdminEmptyView({required this.emptyMessage, super.key});

  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(emptyMessage, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
