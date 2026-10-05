import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';

/// Deletes the signed-in account, from anywhere in the app.
///
/// Separate from the sign-out controller rather than an extra argument to it,
/// because the two differ in what the user is being told. Signing out leaves the
/// account and can be undone by signing in; deleting it cannot, and the wording,
/// the confirmation and the button colour all have to say so. One function with a
/// flag would push that distinction back into every call site.
final deleteAccountControllerProvider =
    Provider<Future<void> Function()>((ref) {
  return () async {
    final failure = await _run(ref);
    // The session ends only when the account is actually gone. A failure means
    // the server still holds the account *and* the tokens are still valid, so
    // signing out here would tear down the screen before it could explain what
    // happened and would leave the user signed out of an account they had every
    // reason to expect to be erased.
    if (failure == null) {
      ref.read(sessionControllerProvider.notifier).signedOut();
      return;
    }
    throw failure;
  };
});

Future<Failure?> _run(Ref ref) async {
  try {
    await ref.read(authRepositoryProvider).deleteAccount();
    return null;
  } on Failure catch (failure) {
    // Surfaced as a [Failure] rather than a raw exception so the screen renders
    // a sentence about what happened. A `DioException` reaching this far would
    // put a socket error or a problem document on screen as text.
    return failure;
  }
}
