import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/constants/app_dimens.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/data/datasources/remote_academics_datasource.dart';
import 'package:peerpass/features/auth/data/models/academic_fallback.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';

class BecomeTutorScreen extends ConsumerStatefulWidget {
  const BecomeTutorScreen({super.key});

  @override
  ConsumerState<BecomeTutorScreen> createState() => _BecomeTutorScreenState();
}

class _BecomeTutorScreenState extends ConsumerState<BecomeTutorScreen> {
  final TextEditingController _evidenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  String _source = 'transcript';
  String? _courseUnitId;
  String? _gradeId;
  bool _submitting = false;

  @override
  void dispose() {
    _evidenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(sessionControllerProvider).profile;
    final universityId = profile?.universityId ?? '';
    final facultyId = profile?.facultyId;
    final courseUnitScope = (universityId: universityId, subjectId: facultyId);
    final courseUnitsAsync = ref.watch(courseUnitsProvider(courseUnitScope));
    final gradesAsync = ref.watch(gradesProvider(universityId));
    final universitiesAsync = ref.watch(universitiesProvider);

    final courseUnits = courseUnitsAsync.maybeWhen(
      data: (items) => items,
      orElse: () => const <CourseUnitOption>[],
    );
    final liveGrades = gradesAsync.maybeWhen(
      data: (items) => items,
      orElse: () => const <GradeOption>[],
    );
    final isMust = universitiesAsync.maybeWhen(
      data: (items) => items.any(
        (university) =>
            university.publicId == universityId &&
            university.name == mustFallbackUniversityName,
      ),
      orElse: () => false,
    );
    final grades = liveGrades.isNotEmpty || !isMust
        ? liveGrades
        : mustFallbackGrades;

    if (_courseUnitId == null && courseUnits.isNotEmpty) {
      _courseUnitId = courseUnits.first.publicId;
    }
    if (liveGrades.isNotEmpty && isMustFallbackGrade(_gradeId)) {
      _gradeId = null;
    }

    final canSubmit =
        !_submitting &&
        profile != null &&
        profile.universityId != null &&
        profile.facultyId != null &&
        courseUnits.any((unit) => unit.publicId == _courseUnitId) &&
        _courseUnitId != null &&
        _gradeId != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Become a tutor')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref
              ..invalidate(courseUnitsProvider(courseUnitScope))
              ..invalidate(gradesProvider(universityId))
              ..invalidate(universitiesProvider);
            await Future.wait([
              ref.read(courseUnitsProvider(courseUnitScope).future),
              ref.read(gradesProvider(universityId).future),
            ]);
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppDimens.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Submit your academic proof',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: AppDimens.md),
                Text(
                  'A verified grade makes you eligible for tutoring requests once it is reviewed.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: AppDimens.xl),
                if (profile == null || profile.universityId == null)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(AppDimens.lg),
                      child: Text(
                        'Complete your profile before submitting tutor proof.',
                      ),
                    ),
                  )
                else ...[
                  _buildDropdown<String>(
                    label: 'Course unit',
                    value:
                        courseUnits.any(
                          (unit) => unit.publicId == _courseUnitId,
                        )
                        ? _courseUnitId
                        : null,
                    items: [
                      for (final unit in courseUnits)
                        DropdownMenuItem(
                          value: unit.publicId,
                          child: Text('${unit.code} · ${unit.name}'),
                        ),
                    ],
                    onChanged: courseUnits.isEmpty
                        ? null
                        : (value) => setState(() => _courseUnitId = value),
                  ),
                  const SizedBox(height: AppDimens.md),
                  _buildDropdown<String>(
                    label: 'Grade',
                    value: _gradeId,
                    hint: 'Select grade',
                    items: [
                      const DropdownMenuItem<String>(
                        child: Text('Select grade'),
                      ),
                      for (final grade in grades)
                        DropdownMenuItem(
                          value: grade.publicId,
                          child: Text(
                            '${grade.label} (${grade.gradePoints.toStringAsFixed(1)})',
                          ),
                        ),
                    ],
                    onChanged: grades.isEmpty
                        ? null
                        : (value) => setState(() => _gradeId = value),
                  ),
                  if (isMust && liveGrades.isEmpty) ...[
                    const SizedBox(height: AppDimens.sm),
                    Text(
                      'Showing the saved MUST grading scale while we refresh the catalogue.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (gradesAsync.hasError)
                      TextButton(
                        onPressed: () =>
                            ref.invalidate(gradesProvider(universityId)),
                        child: const Text('Retry grades'),
                      ),
                  ],
                  const SizedBox(height: AppDimens.md),
                  _buildDropdown<String>(
                    label: 'Evidence source',
                    value: _source,
                    items: const [
                      DropdownMenuItem(
                        value: 'transcript',
                        child: Text('Transcript'),
                      ),
                      DropdownMenuItem(
                        value: 'portfolio',
                        child: Text('Portfolio'),
                      ),
                      DropdownMenuItem(
                        value: 'manual',
                        child: Text('Manual record'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _source = value ?? 'transcript'),
                  ),
                  const SizedBox(height: AppDimens.md),
                  TextFormField(
                    controller: _evidenceController,
                    decoration: const InputDecoration(
                      labelText: 'Evidence reference or link',
                      hintText: 'https://... or transcript reference',
                    ),
                  ),
                  const SizedBox(height: AppDimens.md),
                  TextFormField(
                    controller: _notesController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Notes for the reviewer',
                      hintText: 'Optional context for faculty review',
                    ),
                  ),
                  const SizedBox(height: AppDimens.xl),
                  FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: const Icon(Icons.send_outlined),
                    label: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit proof'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final profile = ref.read(sessionControllerProvider).profile;
    final universityId = profile?.universityId;
    if (profile == null ||
        universityId == null ||
        _courseUnitId == null ||
        _gradeId == null) {
      return;
    }

    setState(() => _submitting = true);

    try {
      var gradeId = _gradeId!;
      if (isMustFallbackGrade(gradeId)) {
        final liveGrades = await ref
            .read(authRepositoryProvider)
            .grades(universityId: universityId);
        final fallback = mustFallbackGrades.firstWhere(
          (grade) => grade.publicId == gradeId,
        );
        final resolved = liveGrades.where(
          (grade) =>
              grade.label == fallback.label &&
              grade.gradePoints == fallback.gradePoints,
        );
        if (resolved.isEmpty) {
          throw StateError(
            'The MUST grading catalogue is unavailable. Please retry and try again.',
          );
        }
        gradeId = resolved.first.publicId;
      }

      await ref
          .read(authControllerProvider)
          .submitTutorProof(
            courseUnitId: _courseUnitId!,
            gradeId: gradeId,
            source: _source,
            evidenceReference: _evidenceController.text.trim().isEmpty
                ? null
                : _evidenceController.text.trim(),
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
          );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your tutor proof was submitted and is awaiting review.',
          ),
        ),
      );
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } on Failure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('We could not submit your tutor proof. Try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Widget _buildDropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
    String? hint,
  }) {
    return DropdownButtonFormField<T>(
      key: ValueKey(label),
      initialValue: value,
      decoration: InputDecoration(labelText: label, hintText: hint),
      items: items,
      onChanged: onChanged,
    );
  }
}
