import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass_admin/core/models/admin_session.dart';
import 'package:peerpass_admin/core/providers/admin_providers.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/audit_log_screen.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/competencies_screen.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/tutor_standings_screen.dart';
import 'package:peerpass_admin/features/admin/presentation/screens/users_screen.dart';

/// The signed-in console: one admin list at a time, plus the way out of it.
///
/// Signing out goes through [SessionController], not straight to the transport,
/// because dropping the tokens and dropping the session have to happen
/// together. Setting the session to null is what unmounts every list below and
/// therefore what takes the fetched records off the screen.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({required this.session, super.key});

  final AdminSession session;

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

/// Below this a rail would take a third of the window, so the destinations move
/// to a bar along the bottom.
const double _railBreakpoint = 700;

const _destinations = <_ShellDestination>[
  _ShellDestination(
    icon: Icon(Icons.people_outline),
    selectedIcon: Icon(Icons.people),
    label: 'Users',
  ),
  _ShellDestination(
    icon: Icon(Icons.verified_outlined),
    selectedIcon: Icon(Icons.verified),
    label: 'Competencies',
  ),
  _ShellDestination(
    icon: Icon(Icons.verified_user_outlined),
    selectedIcon: Icon(Icons.verified_user),
    label: 'Tutor standing',
  ),
  _ShellDestination(
    icon: Icon(Icons.history),
    selectedIcon: Icon(Icons.history),
    label: 'Audit log',
  ),
];

/// The screens the rail and the bar are built from, in destination order.
const _screens = <Widget>[
  UsersScreen(),
  CompetenciesScreen(),
  TutorStandingsScreen(),
  AuditLogScreen(),
];

/// The console's navigation destinations, in the order the screens appear.
class _ShellDestination {
  const _ShellDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final Widget icon;
  final Widget selectedIcon;
  final String label;
}

class _AdminShellState extends ConsumerState<AdminShell> {
  int _selected = 0;

  void _select(int index) => setState(() => _selected = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PeerPass Admin'),
        actions: [
          // Flexible so a long address ellipsises instead of pushing the sign
          // out button off the edge of a narrow window.
          Flexible(
            child: Text(
              widget.session.email,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 16),
          TextButton(
            onPressed: () => ref.read(sessionProvider.notifier).signOut(),
            child: const Text('Sign out'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _railBreakpoint) {
            return _screens[_selected];
          }
          return Row(
            children: [
              NavigationRail(
                selectedIndex: _selected,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final destination in _destinations)
                    NavigationRailDestination(
                      icon: destination.icon,
                      selectedIcon: destination.selectedIcon,
                      label: Text(destination.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _screens[_selected]),
            ],
          );
        },
      ),
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth < _railBreakpoint
            ? NavigationBar(
                selectedIndex: _selected,
                onDestinationSelected: _select,
                destinations: [
                  for (final destination in _destinations)
                    NavigationDestination(
                      icon: destination.icon,
                      selectedIcon: destination.selectedIcon,
                      label: destination.label,
                    ),
                ],
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
