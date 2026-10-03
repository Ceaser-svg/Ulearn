import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/core/theme/admin_theme.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/admin_shell.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/sign_in_screen.dart';

/// The console, and its single authentication gate.
///
/// The session decides which of the two trees exists. There is no route to
/// reach the shell without one and no state that keeps a list alive after the
/// session is gone, so a signed-out console cannot render a fetched record
/// even for a frame.
class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'PeerPass Admin',
      debugShowCheckedModeBanner: false,
      theme: buildAdminTheme(),
      home: session == null
          ? const SignInScreen()
          : AdminShell(session: session),
    );
  }
}
