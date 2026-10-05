import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';

/// Moves the signed-in account to a different faculty.
///
/// Its own provider rather than a call into the auth feature's onboarding
/// controller: onboarding is wizard state, and driving it from the profile screen
/// would mean claiming the student is back in the wizard when what they asked for
/// was to correct one field. It reaches auth the same way every other
/// cross-feature action does, through the repository contract, and refreshes the
/// session from the record the API returns rather than from the value sent.
///
/// One consequence is worth stating because it is not obvious from the call:
/// changing faculty clears the primary course units chosen under the old one, so
/// the account is briefly short of a declared module again. The onboarding gate
/// reads that as unfinished and takes the student back through the wizard, which
/// is the intended outcome -- their old modules belong to a catalogue they have
/// left. The caller is told about it in the confirmation copy so it does not read
/// as a fault.
final changeFacultyControllerProvider = Provider<Future<void> Function(String)>(
  (ref) {
    return (facultyId) async {
      final profile = await ref
          .read(authRepositoryProvider)
          .updateProfile(facultyId: facultyId);
      ref.read(sessionControllerProvider.notifier).signedIn(profile);
    };
  },
);
