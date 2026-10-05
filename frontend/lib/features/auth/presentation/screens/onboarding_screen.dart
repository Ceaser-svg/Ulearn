import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/university_option.dart';
import 'package:peerpass/core/widgets/content_width_limiter.dart';
import 'package:peerpass/core/widgets/empty_view.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';
import 'package:peerpass/features/auth/presentation/providers/onboarding_providers.dart';
import 'package:peerpass/features/auth/presentation/widgets/selection_check.dart';
/// The three steps a new account has to complete before it can be used.
///
/// The wizard is a wizard and not one long form because the parts save
/// independently. A student who force-quits after the name step comes back to a
/// half-filled wizard rather than an empty one, which is the difference between
/// resuming and starting over on a metered connection.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  Future<void> _saveAndAdvance() {
    // The controller keeps the reason on the state, so the screen only has to
    // ask it to try. A false return means the step did not move, and the
    // controller has already recorded why.
    //
    // Whether the catalogue came back empty is handed in rather than looked up by
    // the controller, which may not read a provider that depends on it. `null`
    // while loading and again after a failure, and `isEmpty` is only true of a
    // list that arrived, so neither opens the module step.
    final universityId = ref.read(onboardingControllerProvider).universityId;
    final facultyId = ref.read(onboardingControllerProvider).facultyId;
    final units = universityId != null && facultyId != null
        ? ref.read(
            courseUnitsProvider((
              universityId: universityId,
              subjectId: facultyId,
            )),
          )
        : null;
    final emptyCatalogue = units?.asData?.value.isEmpty == true;
    return ref
        .read(onboardingControllerProvider.notifier)
        .saveAndAdvance(facultyHasNoCourseUnits: emptyCatalogue);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final canAdvance = ref.watch(canAdvanceWizardProvider);

    return Scaffold(
      appBar: AppBar(
        // No leading control on the first step: there is nowhere before it, and
        // a back arrow that leaves the wizard would strand a student whose
        // account is not usable yet.
        leading: state.step == OnboardingStep.name
            ? null
            : BackButton(
                onPressed: ref.read(onboardingControllerProvider.notifier).back,
              ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _Progress(step: state.step),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: ContentWidthLimiter(
                    child: Padding(
                      padding: const EdgeInsets.all(AppDimens.xl),
                      child: switch (state.step) {
                        OnboardingStep.name => const _NameStep(),
                        OnboardingStep.academicContext =>
                          const _AcademicContextStep(),
                        OnboardingStep.primaryModules =>
                          const _PrimaryModulesStep(),
                      },
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(AppDimens.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state.failure case final failure?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppDimens.md),
                        child: Text(
                          _messageFor(failure),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    FilledButton(
                      onPressed: canAdvance && !state.saving
                          ? _saveAndAdvance
                          : null,
                      child: state.saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              state.step != OnboardingStep.primaryModules
                                  ? 'Continue'
                                  : 'Finish',
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What to say about a refused save, by cause.
///
/// A [ValidationFailure] speaks for itself: the API's own per-field messages are
/// more specific than anything this screen could invent, and inventing a generic
/// message in their place is how a student ends up guessing which field the API
/// was unhappy about. Everything else gets a cause-appropriate instruction,
/// because "something went wrong" tells a student on a metered connection
/// nothing about whether retrying is worth anything.
String _messageFor(Failure failure) => switch (failure) {
  ValidationFailure(:final fieldErrors) when fieldErrors.isNotEmpty =>
    fieldErrors.values.join(' '),
  NetworkFailure() =>
    'Could not reach PeerPass. Check your connection and try again.',
  _ => 'Could not save. Try again.',
};

/// Three pips, filled progressively.
class _Progress extends StatelessWidget {
  const _Progress({required this.step});

  final OnboardingStep step;

  @override
  Widget build(BuildContext context) {
    final done1 =
        step == OnboardingStep.academicContext ||
        step == OnboardingStep.primaryModules;
    final done2 = step == OnboardingStep.primaryModules;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.xl,
        vertical: AppDimens.sm,
      ),
      child: Row(
        children: [
          Expanded(child: _pip(context, filled: true)),
          const SizedBox(width: AppDimens.sm),
          Expanded(child: _pip(context, filled: done1)),
          const SizedBox(width: AppDimens.sm),
          Expanded(child: _pip(context, filled: done2)),
        ],
      ),
    );
  }

  Widget _pip(BuildContext context, {required bool filled}) {
    return Container(
      height: 4,
      decoration: BoxDecoration(
        color: filled
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
      ),
    );
  }
}

/// Step one: what the student is called.
class _NameStep extends ConsumerStatefulWidget {
  const _NameStep();

  @override
  ConsumerState<_NameStep> createState() => _NameStepState();
}

class _NameStepState extends ConsumerState<_NameStep> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(onboardingControllerProvider).fullName,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('What is your name?', style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppDimens.sm),
        Text(
          'Tutors and other students will see this.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppDimens.xl),
        TextField(
          controller: _controller,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Full name',
            prefixIcon: Icon(Icons.person_outline),
          ),
          onChanged: ref
              .read(onboardingControllerProvider.notifier)
              .setFullName,
        ),
      ],
    );
  }
}

/// Step two: where the student studies, and the consent to record it.
class _AcademicContextStep extends ConsumerWidget {
  const _AcademicContextStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Where do you study?', style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppDimens.sm),
        Text(
          'Used to show you tutors and units that are relevant to you.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppDimens.xl),
        ref
            .watch(universitiesProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ReferenceDataUnavailable(
                message: 'Could not load universities. Check your connection and try again.',
                onRetry: () => ref.invalidate(universitiesProvider),
              ),
              data: (universities) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (universities.any((university) => university.isFallback))
                    _FallbackNotice(
                      onRetry: () => ref.invalidate(universitiesProvider),
                    ),
                  const _UniversityPicker(),
                ],
              ),
            ),
        const SizedBox(height: AppDimens.lg),
        const _FacultySection(),
        const SizedBox(height: AppDimens.lg),
        _YearPicker(),
        const SizedBox(height: AppDimens.xl),
        _ConsentBox(),
      ],
    );
  }
}

class _FacultySection extends ConsumerWidget {
  const _FacultySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final universityId = ref.watch(onboardingControllerProvider).universityId;
    if (universityId == null) return const _FacultyPicker();
    final faculties = ref.watch(facultiesProvider(universityId));

    return faculties.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ReferenceDataUnavailable(
        message:
            'Could not load faculties. Check your connection and try again.',
        onRetry: () => ref.invalidate(facultiesProvider(universityId)),
      ),
      data: (faculties) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (faculties.any(
            (faculty) => faculty.publicId.startsWith('fallback:'),
          ))
            _FallbackNotice(
              onRetry: () => ref.invalidate(facultiesProvider(universityId)),
            ),
          const _FacultyPicker(),
        ],
      ),
    );
  }
}

class _ReferenceDataUnavailable extends StatelessWidget {
  const _ReferenceDataUnavailable({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: AppDimens.sm),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}

class _FallbackNotice extends StatelessWidget {
  const _FallbackNotice({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              'Showing saved MUST options while we refresh the catalogue.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// The university dropdown.
///
/// Watches the provider itself rather than taking the list, so the `when` above
/// is only deciding between loading, failed, and present. `const` is correct
/// here: a `ConsumerWidget` that reads nothing from its parent can be const.
class _UniversityPicker extends ConsumerWidget {
  const _UniversityPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final universities = ref.watch(universitiesProvider).value;
    final selected = ref.watch(onboardingControllerProvider).universityId;

    final catalogue = universities ?? const <UniversityOption>[];
    // The *value* has to exist among the *items*, so a value from a catalogue
    // that is no longer loaded is dropped here. The items themselves are never
    // filtered: a list holding only the selected entry is an empty dropdown to a
    // student who has not chosen yet, which is a wizard that cannot be finished.
    final selectionIsValid = catalogue.any(
      (university) => university.publicId == selected,
    );

    return DropdownButtonFormField<String>(
      initialValue: selectionIsValid ? selected : null,
      // Without this the field sizes itself to the longest faculty name in the
      // catalogue, which on a narrow handset overflows the input box.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'University',
        prefixIcon: Icon(Icons.school_outlined),
      ),
      items: [
        for (final university in catalogue)
          DropdownMenuItem(
            value: university.publicId,
            child: Text(university.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: ref.read(onboardingControllerProvider.notifier).setUniversity,
    );
  }
}

class _FacultyPicker extends ConsumerWidget {
  const _FacultyPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    // Nothing to pick from until a university is chosen: the endpoint returns
    // the catalogue, not a filtered set, so a faculty chosen before the
    // university would be a guess about a catalogue the student has not seen.
    final enabled = state.universityId != null;
    final faculties = enabled
        ? ref.watch(facultiesProvider(state.universityId!)).value
        : const <Subject>[];

    // The wizard clears the faculty when the university changes, so a value left
    // over from the old catalogue must not be handed back to a dropdown that no
    // longer contains it.
    final selectionIsValid =
        faculties?.any((faculty) => faculty.publicId == state.facultyId) ??
        false;

    return DropdownButtonFormField<String>(
      initialValue: selectionIsValid ? state.facultyId : null,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Faculty',
        prefixIcon: Icon(Icons.account_balance_outlined),
      ),
      items: [
        for (final faculty in faculties ?? const <Subject>[])
          DropdownMenuItem(
            value: faculty.publicId,
            child: Text(faculty.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled
          ? ref.read(onboardingControllerProvider.notifier).setFaculty
          : null,
    );
  }
}

class _YearPicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(onboardingControllerProvider).yearOfStudy;

    return DropdownButtonFormField<int>(
      initialValue: selected,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Year of study',
        prefixIcon: Icon(Icons.timeline_outlined),
      ),
      // One through six, matching the API's own constraint. The last two years
      // of a six-year degree are the ones a tutor is still useful to, but the
      // API accepts the whole range and inventing a narrower client rule would
      // reject students the server would have taken.
      items: [
        for (var year = 1; year <= 6; year++)
          DropdownMenuItem(value: year, child: Text('Year $year')),
      ],
      onChanged: ref.read(onboardingControllerProvider.notifier).setYearOfStudy,
    );
  }
}

/// The consent box, which is a gate rather than a preference.
///
/// Consent is not collected to be nice to a data-protection policy. The academic
/// context above is the thing matching later depends on, and storing it without
/// agreement is storing academic data about a person who never agreed to it. So
/// the box has to be ticked before Finish is enabled, and the Finish button says
/// what agreeing means.
class _ConsentBox extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(onboardingControllerProvider);

    return InkWell(
      onTap: () => ref
          .read(onboardingControllerProvider.notifier)
          .setConsent(value: !state.academicDataConsented),
      borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(AppDimens.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectionCheck(selected: state.academicDataConsented),
            const SizedBox(width: AppDimens.md),
            Expanded(
              child: Text(
                'I agree that PeerPass may store my name, university, '
                'faculty and year to find me tutors and units.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Step three: the course units the student expects to need help with.
class _PrimaryModulesStep extends ConsumerWidget {
  const _PrimaryModulesStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(onboardingControllerProvider);
    final universityId = state.universityId;
    final facultyId = state.facultyId;

    if (universityId == null || facultyId == null) {
      return Text(
        'Choose a university and faculty first.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Which units might you need help with?',
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: AppDimens.sm),
        Text(
          'Choose at least one. You can change these later.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppDimens.xl),
        ref
            .watch(
              courseUnitsProvider((
                universityId: universityId,
                subjectId: facultyId,
              )),
            )
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => Text(
                'Could not load course units. Check your connection and try again.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              data: (units) => units.isEmpty
                  // Four of the six seeded faculties hold no course units, so a
                  // student in one arrives here with nothing to pick and no way
                  // past the step. Said plainly, because a bare heading with
                  // nothing under it reads as a bug in the app rather than a
                  // fact about the catalogue.
                  ? const EmptyView(
                      icon: Icons.menu_book_outlined,
                      title: 'No course units yet',
                      message:
                          'Your faculty has not published any course units yet, '
                          'so there is nothing to choose here. You can finish '
                          'setting up your profile and add units later.',
                    )
                  : Wrap(
                      spacing: AppDimens.sm,
                      runSpacing: AppDimens.sm,
                      children: [
                        for (final unit in units)
                          FilterChip(
                            label: Text('${unit.code} - ${unit.name}'),
                            selected: state.primaryModuleIds.contains(
                              unit.publicId,
                            ),
                            onSelected: (_) => ref
                                .read(onboardingControllerProvider.notifier)
                                .togglePrimaryModule(unit.publicId),
                          ),
                      ],
                    ),
            ),
      ],
    );
  }
}
