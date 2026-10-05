import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:peerpass/app/router.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/course_unit.dart';
import 'package:peerpass/core/widgets/content_width_limiter.dart';
import 'package:peerpass/core/widgets/empty_view.dart';
import 'package:peerpass/core/widgets/failure_view.dart';
import 'package:peerpass/core/widgets/loading_view.dart';
import 'package:peerpass/features/matching/presentation/providers/matching_providers.dart';

/// The course unit to find a tutor for.
///
/// Picked first and matched second, because that is the order the API asks for:
/// `POST /v1/matching/suggestions` answers about a unit and nothing else, so a
/// client that asked for "tutors" without saying which course would be guessing
/// on the student's behalf.
///
/// The list is the student's own university's catalogue, read from the same
/// endpoint onboarding reads. It is a plain list rather than a search box,
/// because a picker that hides half the catalogue behind a filter is a picker
/// that says no tutor teaches this unit when the student has not looked.
class CourseUnitPickerScreen extends ConsumerWidget {
  const CourseUnitPickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final units = ref.watch(courseUnitOptionsProvider);
    final failure = units.hasError ? failureFor(units.error!) : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Find a tutor')),
      body: SafeArea(
        child: Center(
          child: ContentWidthLimiter(
            child: switch (failure) {
              final failure? => FailureView(
                failure: failure,
                onRetry: () => ref.invalidate(courseUnitOptionsProvider),
              ),
              null => switch (units.value) {
                final loaded? => _UnitList(
                  units: loaded,
                  onRefresh: () =>
                      ref.refresh(courseUnitOptionsProvider.future),
                ),
                null => const LoadingView(message: 'Loading course units'),
              },
            },
          ),
        ),
      ),
    );
  }
}

/// The units, or the honest answer that there are none.
class _UnitList extends StatelessWidget {
  const _UnitList({required this.units, required this.onRefresh});

  final List<CourseUnit> units;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (units.isEmpty) {
      // An empty catalogue and a university with no tutors are different facts,
      // and this one is the first: there is nothing to search for yet. The
      // catalogue is scoped to the student's own faculty, so that is the thing
      // to name -- telling them their university has published nothing would be
      // wrong whenever a sibling faculty has courses, which is four faculties
      // out of six in the pilot seed.
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: AppDimens.xxl),
            EmptyView(
              icon: Icons.menu_book_outlined,
              title: 'No course units to search',
              message:
                  'Your faculty has not published any course units yet, so '
                  'there is nothing to look for a tutor in. This is not an '
                  'error.',
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: units.length,
        itemBuilder: (context, index) => _UnitTile(unit: units[index]),
      ),
    );
  }
}

/// One unit: its code and its name, and where it leads.
class _UnitTile extends StatelessWidget {
  const _UnitTile({required this.unit});

  final CourseUnit unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      onTap: () => context.push(AppRoutes.matchResultsPath(unit.publicId)),
      title: Text(unit.code, style: theme.textTheme.titleMedium),
      subtitle: Text(unit.name),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
