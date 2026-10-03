import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
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
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Role'),
                    subtitle: Text(_roleLabel(profile)),
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
