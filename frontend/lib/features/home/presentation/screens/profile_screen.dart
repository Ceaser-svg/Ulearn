import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/widgets/failure_view.dart';
import 'package:peerpass/features/home/presentation/providers/change_faculty_controller.dart';
import 'package:peerpass/features/home/presentation/providers/profile_providers.dart';
import 'package:peerpass/features/home/presentation/providers/sign_out_controller.dart';
import 'package:peerpass/features/home/presentation/widgets/delete_account_tile.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(sessionControllerProvider).profile;
    final theme = Theme.of(context);
    final university = profile?.universityId == null
        ? null
        : ref.watch(universityByIdProvider(profile!.universityId!));

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppDimens.xl),
          children: [
            CircleAvatar(radius: 32, child: Text(profile?.initials ?? '?')),
            const SizedBox(height: AppDimens.md),
            Text(
              profile?.fullName ?? 'PeerPass student',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppDimens.xs),
            Text(
              profile?.email ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppDimens.xl),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.school_outlined),
                    title: const Text('University'),
                    subtitle: university == null
                        ? const Text('Not provided')
                        : university.when(
                            data: (value) => Text(value ?? 'Unavailable'),
                            loading: () => const Text('Loading...'),
                            error: (_, _) => const Text('Unavailable'),
                          ),
                  ),
                  _FacultyTile(profile: profile),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Role'),
                    subtitle: Text(_roleLabel(profile)),
                  ),
                  // The tutor-application row lives here rather than on the
                  // home screen because it is an account fact, and because home
                  // may not import another feature's presentation: this pushes a
                  // route instead, which is what the app router exists for.
                  //
                  // It is shown to every signed-in user, not only to tutors. A
                  // student who has not applied yet needs it too -- it is where
                  // the screen says so and offers the form.
                  ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('Tutor applications'),
                    subtitle: const Text('Where your submitted proofs stand'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(AppRoutes.myApplications),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.lg),
            FilledButton.icon(
              onPressed: () => ref.read(signOutControllerProvider)(),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
            const SizedBox(height: AppDimens.lg),
            const DeleteAccountTile(),
          ],
        ),
      ),
    );
  }

  String _roleLabel(UserProfile? profile) {
    if (profile?.hasRole(UserRole.tutor) ?? false) {
      return 'Student and tutor';
    }
    return 'Student';
  }
}

/// The student's faculty, and the control that changes it.
///
/// Editable because a wrong faculty is not recoverable on its own: the course
/// catalogue and the tutor rail are both scoped by it, so a student who picked
/// the wrong one sees an empty product and no reason why. Read-only meant the only
/// way out was deleting the account.
class _FacultyTile extends ConsumerWidget {
  const _FacultyTile({required this.profile});

  final UserProfile? profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final universityId = profile?.universityId;
    final facultyId = profile?.facultyId;

    // Faculties belong to a university, so with none chosen there is nothing to
    // offer and the tile says so rather than opening an empty sheet. The wizard
    // is the place that fixes this, and its gate already routes here.
    if (universityId == null) {
      return const ListTile(
        leading: Icon(Icons.account_balance_outlined),
        title: Text('Faculty'),
        subtitle: Text('Choose a university first'),
      );
    }

    // Resolved from the same list the picker opens rather than through a lookup
    // by id: it is one request instead of two, and the name shown is then
    // guaranteed to be one of the names that can be chosen.
    String? name;
    if (facultyId != null) {
      final faculties = ref
          .watch(facultiesForUniversityProvider(universityId))
          .value;
      if (faculties != null) {
        for (final faculty in faculties) {
          if (faculty.publicId == facultyId) {
            name = faculty.name;
            break;
          }
        }
      }
    }

    return ListTile(
      leading: const Icon(Icons.account_balance_outlined),
      title: const Text('Faculty'),
      subtitle: Text(
        name ?? (facultyId == null ? 'Not provided' : 'Loading...'),
      ),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => _chooseFaculty(context, ref),
    );
  }

  Future<void> _chooseFaculty(BuildContext context, WidgetRef ref) async {
    final universityId = profile?.universityId;
    if (universityId == null) return;
    final current = profile?.facultyId;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) =>
          _FacultySheet(universityId: universityId, currentFacultyId: current),
    );
    if (chosen == null || !context.mounted) return;

    try {
      await ref.read(changeFacultyControllerProvider)(chosen);
      if (!context.mounted) return;
      // Said rather than left to be discovered, because the change drops the
      // primary modules chosen under the old faculty and the app will ask for new
      // ones as a result. Without this the student sees a jump to onboarding and
      // no explanation for it.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Faculty updated. Choose the course units for your new faculty.',
          ),
        ),
      );
    } on Failure catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not change faculty. Try again.')),
      );
    }
  }
}

/// The list of faculties, with the current one marked.
class _FacultySheet extends ConsumerWidget {
  const _FacultySheet({
    required this.universityId,
    required this.currentFacultyId,
  });

  final String universityId;
  final String? currentFacultyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final faculties = ref.watch(facultiesForUniversityProvider(universityId));

    return SafeArea(
      child: faculties.when(
        loading: () => const SizedBox(
          height: 240,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => FailureView(
          failure: error is Failure ? error : const UnknownFailure(),
          onRetry: () =>
              ref.invalidate(facultiesForUniversityProvider(universityId)),
        ),
        data: (faculties) => ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.xl,
                0,
                AppDimens.xl,
                AppDimens.sm,
              ),
              child: Text(
                'Your faculty decides which courses you can ask for help with.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final faculty in faculties)
              ListTile(
                title: Text(faculty.name, overflow: TextOverflow.ellipsis),
                trailing: faculty.publicId == currentFacultyId
                    ? const Icon(Icons.check)
                    : null,
                selected: faculty.publicId == currentFacultyId,
                onTap: () => Navigator.of(context).pop(faculty.publicId),
              ),
          ],
        ),
      ),
    );
  }
}
