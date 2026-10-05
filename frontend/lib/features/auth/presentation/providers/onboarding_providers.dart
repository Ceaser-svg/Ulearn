import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/features/auth/data/models/academic_fallback.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';

/// Which step of the wizard the student is on.
///
/// Two steps in this release. A third, the units they want help with, is
/// deferred: the units a tutor can be matched on depend on the matching rules
/// being settled, and a student who picks units the API will not match them
/// against has been told something untrue.
enum OnboardingStep {
  name,
  academicContext,
  primaryModules;

  OnboardingStep? get next => switch (this) {
    OnboardingStep.name => OnboardingStep.academicContext,
    OnboardingStep.academicContext => OnboardingStep.primaryModules,
    OnboardingStep.primaryModules => null,
  };
}

/// The wizard's own state.
///
/// Separate from the stored profile on purpose. The wizard is a draft until the
/// student presses the button on a step, and keeping the draft here means a
/// student who picks a faculty, goes back, and picks another never sent the
/// first one anywhere.
@immutable
class OnboardingState {
  const OnboardingState({
    this.step = OnboardingStep.name,
    this.fullName = '',
    this.universityId,
    this.facultyId,
    this.yearOfStudy,
    this.academicDataConsented = false,
    this.primaryModuleIds = const [],
    this.saving = false,
    this.failure,
  });

  final OnboardingStep step;

  final String fullName;

  final String? universityId;

  final String? facultyId;

  final int? yearOfStudy;

  final bool academicDataConsented;

  final List<String> primaryModuleIds;

  /// Whether a save is in flight.
  ///
  /// Held on the state so the button can disable itself. A step saved twice would
  /// be harmless -- the API merges partial updates -- but the second write is
  /// almost always a double tap, and showing progress is kinder than accepting it.
  final bool saving;

  /// Why the last save was refused, when it was.
  ///
  /// Held here rather than thrown, because the student is standing in front of the
  /// wizard when it happens and the wizard is the only thing that can render it.
  /// A [ValidationFailure] in particular carries the API's per-field messages, and
  /// discarding them is what leaves a student tapping Next with nothing happening.
  final Failure? failure;

  /// Whether the current step's own inputs are complete.
  ///
  /// Per step, because the Next button is bound to the step in view and must not
  /// be enabled by something filled in on a later one.
  bool get canContinue => switch (step) {
    OnboardingStep.name => fullName.trim().isNotEmpty,
    OnboardingStep.academicContext =>
      universityId != null &&
          facultyId != null &&
          yearOfStudy != null &&
          academicDataConsented,
    OnboardingStep.primaryModules => primaryModuleIds.isNotEmpty,
  };

  OnboardingState copyWith({
    OnboardingStep? step,
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryModuleIds,
    bool? saving,
    Failure? failure,
    bool clearFaculty = false,
    bool clearPrimaryModules = false,
    bool clearFailure = false,
  }) {
    return OnboardingState(
      step: step ?? this.step,
      fullName: fullName ?? this.fullName,
      universityId: universityId ?? this.universityId,
      // An explicit clear, because "the student changed faculty and has not
      // chosen a new one" is a real state that a null `facultyId` cannot express
      // through a `??` default.
      facultyId: clearFaculty ? null : (facultyId ?? this.facultyId),
      yearOfStudy: yearOfStudy ?? this.yearOfStudy,
      academicDataConsented:
          academicDataConsented ?? this.academicDataConsented,
      primaryModuleIds: clearPrimaryModules
          ? const []
          : (primaryModuleIds ?? this.primaryModuleIds),
      saving: saving ?? this.saving,
      // An explicit clear, for the same reason `clearFaculty` exists: a save that
      // starts must not leave the previous save's complaint on screen.
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnboardingState &&
          other.step == step &&
          other.fullName == fullName &&
          other.universityId == universityId &&
          other.facultyId == facultyId &&
          other.yearOfStudy == yearOfStudy &&
          other.academicDataConsented == academicDataConsented &&
          other.primaryModuleIds == primaryModuleIds &&
          other.saving == saving &&
          other.failure == failure;

  @override
  int get hashCode => Object.hash(
    step,
    fullName,
    universityId,
    facultyId,
    yearOfStudy,
    academicDataConsented,
    primaryModuleIds,
    saving,
    failure,
  );
}

final onboardingControllerProvider =
    NotifierProvider<OnboardingController, OnboardingState>(
      OnboardingController.new,
    );

/// Whether the button under the wizard may be pressed right now.
///
/// The controller's own `canContinue` covers what the student has typed. This adds
/// the one case the draft cannot know: a faculty whose catalogue came back empty
/// has nothing to choose, so the module step must not be able to trap them there.
/// Four of the six seeded faculties hold no course units, and a Finish button that
/// stays disabled over an honest empty state is a student who can never reach the
/// app.
///
/// `asData?.value` is `null` while loading and again after a failure. A failed
/// request is not an empty catalogue, so neither case opens the step: a dropped
/// connection must not be read as a faculty that teaches nothing.
final canAdvanceWizardProvider = Provider<bool>((ref) {
  final state = ref.watch(onboardingControllerProvider);
  if (state.step != OnboardingStep.primaryModules) return state.canContinue;

  final universityId = state.universityId;
  final facultyId = state.facultyId;
  if (universityId == null || facultyId == null) return state.canContinue;

  final units = ref.watch(
    courseUnitsProvider((universityId: universityId, subjectId: facultyId)),
  );
  return state.primaryModuleIds.isNotEmpty ||
      units.asData?.value.isEmpty == true;
});

/// Drives the wizard: collects input, saves one step at a time.
///
/// Holds no user profile and does not decide what is valid. It reads what the
/// API already stored, so a student who force-quits half way through and comes
/// back sees their own answers rather than an empty form.
class OnboardingController extends Notifier<OnboardingState> {
  @override
  OnboardingState build() {
    final profile = ref.read(sessionControllerProvider).profile;
    return OnboardingState(
      fullName: profile?.fullName ?? '',
      universityId: profile?.universityId,
      facultyId: profile?.facultyId,
      yearOfStudy: profile?.yearOfStudy,
      academicDataConsented: profile?.hasConsentedToAcademicData ?? false,
      primaryModuleIds: profile?.primaryCourseUnitIds ?? const [],
    );
  }

  void setFullName(String value) => state = state.copyWith(fullName: value);

  void setUniversity(String? publicId) {
    if (publicId == null) return;
    // A different university is a different catalogue, so the faculty that
    // belonged to the old one is dropped rather than left to be submitted with
    // the new.
    final changed = publicId != state.universityId;
    state = state.copyWith(
      universityId: publicId,
      clearFaculty: changed,
      clearPrimaryModules: changed,
    );
  }

  void setFaculty(String? publicId) {
    if (publicId == null) return;
    final changed = publicId != state.facultyId;
    state = state.copyWith(facultyId: publicId, clearPrimaryModules: changed);
  }

  void setYearOfStudy(int? year) => state = state.copyWith(yearOfStudy: year);

  void setConsent({required bool value}) =>
      state = state.copyWith(academicDataConsented: value);

  void togglePrimaryModule(String id) {
    final current = List<String>.from(state.primaryModuleIds);
    if (current.contains(id)) {
      current.remove(id);
    } else {
      current.add(id);
    }
    state = state.copyWith(primaryModuleIds: current);
  }

  void back() {
    final previous = switch (state.step) {
      OnboardingStep.name => null,
      OnboardingStep.academicContext => OnboardingStep.name,
      OnboardingStep.primaryModules => OnboardingStep.academicContext,
    };
    if (previous != null) state = state.copyWith(step: previous);
  }

  Future<(String, String)> _resolveAcademicSelection({
    required String universityId,
    required String facultyId,
  }) async {
    if (!isMustFallbackUniversity(universityId)) {
      return (universityId, facultyId);
    }

    final repository = ref.read(authRepositoryProvider);
    final universities = await repository.universities();
    final university = universities.firstWhere(
      (candidate) => candidate.name == mustFallbackUniversityName,
      orElse: () => throw const ValidationFailure(
        'MUST options are temporarily unavailable. Try again in a moment.',
      ),
    );
    final facultyName = mustFallbackFacultyName(facultyId);
    if (facultyName == null) {
      throw const ValidationFailure('Choose a faculty before continuing.');
    }
    final faculties = await repository.faculties(
      universityId: university.publicId,
    );
    final faculty = faculties.firstWhere(
      (candidate) => candidate.name == facultyName,
      orElse: () => throw const ValidationFailure(
        'MUST faculties are temporarily unavailable. Try again in a moment.',
      ),
    );
    return (university.publicId, faculty.publicId);
  }

  /// Saves the current step, then advances.
  ///
  /// Returns whether it advanced. A failure is left to the caller to render, and
  /// the step does not move: telling a student they finished onboarding when the
  /// write failed would drop the step on the next cold start.
  ///
  /// [facultyHasNoCourseUnits] is passed in by the screen rather than looked up
  /// here. A controller may not read a provider that depends on itself, and the
  /// answer -- whether the chosen faculty's catalogue came back empty -- lives in
  /// the request the screen already watches. It matters only on the module step,
  /// where it is the difference between a student who can finish and one trapped
  /// against a list that will never contain anything.
  Future<bool> saveAndAdvance({bool facultyHasNoCourseUnits = false}) async {
    final complete =
        state.canContinue ||
        (state.step == OnboardingStep.primaryModules &&
            facultyHasNoCourseUnits);
    if (!complete || state.saving) return false;

    state = state.copyWith(saving: true, clearFailure: true);
    final controller = ref.read(authControllerProvider);

    try {
      switch (state.step) {
        case OnboardingStep.name:
          await controller.updateProfile(fullName: state.fullName.trim());
        case OnboardingStep.academicContext:
          final resolved = await _resolveAcademicSelection(
            universityId: state.universityId!,
            facultyId: state.facultyId!,
          );
          await controller.updateProfile(
            universityId: resolved.$1,
            facultyId: resolved.$2,
            yearOfStudy: state.yearOfStudy,
            // Only sent once the box is ticked. Sending `false` would be a
            // request to record the absence of consent, which is not what the
            // API's field means.
            academicDataConsented: true,
          );
          state = state.copyWith(
            universityId: resolved.$1,
            facultyId: resolved.$2,
          );
        case OnboardingStep.primaryModules:
          // We will update the authController to accept primaryModuleIds soon
          await controller.updateProfile(
            primaryCourseUnitIds: state.primaryModuleIds,
          );
      }
    } on Failure catch (failure) {
      // The wizard does not advance, and the reason is kept so the screen can
      // show it. Telling a student they finished a step that was not stored
      // would drop it on the next cold start.
      state = state.copyWith(saving: false, failure: failure);
      return false;
    } on Object {
      // A programming error rather than an API complaint. Still has to surface
      // as a refusal to advance, so it cannot fall through as a success.
      state = state.copyWith(saving: false, failure: const UnknownFailure());
      return false;
    }

    final next = state.step.next;
    if (next == null) {
      // The last step. The router takes it from here: once the profile no longer
      // needs onboarding, the guard sends the student home on its own.
      state = state.copyWith(saving: false, clearFailure: true);
      return true;
    }

    state = state.copyWith(step: next, saving: false, clearFailure: true);
    return true;
  }
}
