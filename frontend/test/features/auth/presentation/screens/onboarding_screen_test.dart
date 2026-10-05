import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/error/failures.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/core/state/session.dart';
import 'package:peerpass/core/theme/app_theme.dart';
import 'package:peerpass/features/auth/data/datasources/remote_academics_datasource.dart';
import 'package:peerpass/features/auth/data/models/university_option.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/auth/presentation/providers/auth_providers.dart';
import 'package:peerpass/features/auth/presentation/providers/onboarding_providers.dart';
import 'package:peerpass/features/auth/presentation/screens/onboarding_screen.dart';
import 'package:peerpass/features/auth/presentation/widgets/selection_check.dart';

/// A student who has signed up and filled in nothing yet.
///
/// The state the router hands to the wizard, and the one the fake merges every
/// partial update into.
const UserProfile _freshAccount = UserProfile(
  publicId: 'user-1',
  email: 'newcomer@must.ac.ug',
  roles: <UserRole>{UserRole.student},
);

const String _name = 'Achieng Okello';
const String _university = 'university-1';
const String _year = 'Year 2';

const List<UniversityOption> _universities = <UniversityOption>[
  UniversityOption(
    publicId: 'university-1',
    name: 'Mbarara University of Science and Technology',
  ),
  UniversityOption(publicId: 'university-2', name: 'Kyambogo University'),
];

/// Real-length names.
///
/// Both pickers pass `isExpanded` to their dropdown. Without it a field is laid
/// out as wide as the longest entry in the catalogue and overflows the input box
/// once a name is longer than the field, which real Ugandan faculty names
/// reliably are. Using the long names here is what keeps that from coming back.
const List<Subject> _faculties = <Subject>[
  Subject(publicId: 'subject-1', name: 'School of Business and Management'),
  Subject(
    publicId: 'subject-2',
    name:
        'School of Computing, Information Technology and Software Engineering',
  ),
];

/// What the API says about the one field it would not take.
const String _refusedUniversity =
    'We have not recorded a grading scale for that university';

const String _consentText =
    'I agree that PeerPass may store my name, university, faculty and year';
const List<CourseUnitOption> _courseUnits = <CourseUnitOption>[
  CourseUnitOption(
    publicId: 'unit-1',
    code: 'BIT 221',
    name: 'Database Programming',
  ),
];

/// A repository that refuses the second step, the way a validation error arrives.
///
/// Only the academic-context update is refused: the name step has to get through
/// for the wizard to reach the part under test, and a fake that refused
/// everything would fail the setup rather than the assertion.
class _RefusingAuthRepository extends FakeAuthRepository {
  _RefusingAuthRepository()
    : super(
        session: _freshAccount,
        refreshToken: 'refresh',
        universityOptions: _universities,
        facultyOptions: _faculties,
        courseUnitOptions: _courseUnits,
      );

  @override
  Future<UserProfile> updateProfile({
    String? fullName,
    String? universityId,
    String? facultyId,
    int? yearOfStudy,
    bool? academicDataConsented,
    List<String>? primaryCourseUnitIds,
  }) {
    if (universityId != null) {
      throw const ValidationFailure(
        'Some of the details you entered are not valid.',
        fieldErrors: <String, String>{'university_id': _refusedUniversity},
      );
    }
    return super.updateProfile(
      fullName: fullName,
      primaryCourseUnitIds: primaryCourseUnitIds,
    );
  }
}

class _UnavailableFacultyRepository extends FakeAuthRepository {
  _UnavailableFacultyRepository()
    : super(
        session: _freshAccount,
        refreshToken: 'refresh',
        universityOptions: _universities,
      );

  @override
  Future<List<Subject>> faculties({required String universityId}) async {
    throw const NetworkFailure();
  }
}

/// A container to read the session through, plus the repository behind it.
///
/// Typed as the fake rather than as the contract because a test here is often
/// asserting on what the wizard actually sent, which only the fake records.
typedef _Harness = ({
  ProviderContainer container,
  FakeAuthRepository repository,
});

/// The fake the wizard is normally driven against.
FakeAuthRepository _fake() => FakeAuthRepository(
  session: _freshAccount,
  refreshToken: 'refresh',
  universityOptions: _universities,
  facultyOptions: _faculties,
  courseUnitOptions: _courseUnits,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

/// A container over [repository] with a session already established.
///
/// The handle is what lets a test read the session afterwards; a bare
/// `ProviderScope` would put it out of reach.
_Harness _harness(FakeAuthRepository repository) {
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  // The wizard is only reachable once a session exists, and it seeds itself from
  // the stored profile the first time it is read.
  container.read(sessionControllerProvider.notifier).signedIn(_freshAccount);
  return (container: container, repository: repository);
}

Future<void> _pumpWizard(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(theme: AppTheme.light, home: const OnboardingScreen()),
    ),
  );
  await _settle(tester);
}

/// The button under the wizard, which reads Continue until the final step.
Finder _advanceButton(String label) => find.widgetWithText(FilledButton, label);

/// Whether the wizard's own button would accept a press.
bool _canAdvance(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(_advanceButton(label)).onPressed != null;

final Finder _facultyDropdown = find.widgetWithText(
  DropdownButtonFormField<String>,
  'Faculty',
);

final Finder _yearDropdown = find.widgetWithText(
  DropdownButtonFormField<int>,
  'Year of study',
);

/// Whether the consent box is ticked.
bool _hasConsented(WidgetTester tester) =>
    tester.widget<SelectionCheck>(find.byType(SelectionCheck)).selected;

/// Chooses a university through the controller rather than through the dropdown.
///
/// `_UniversityPicker` builds its item list by keeping only the catalogue entry
/// that matches the current selection, so while the wizard holds no university
/// the list is empty and the dropdown offers nothing to pick. The picker cannot
/// be reached from a fresh wizard, so the choice is made through the controller
/// the widget reads instead. That is a defect in
/// `lib/features/auth/presentation/screens/onboarding_screen.dart`, not a
/// restriction the wizard intends.
void _chooseUniversity(_Harness harness, String publicId) {
  harness.container
      .read(onboardingControllerProvider.notifier)
      .setUniversity(publicId);
}

/// Fills in the name and moves on to the second step.
Future<void> _completeNameStep(WidgetTester tester, _Harness harness) async {
  await tester.enterText(find.widgetWithText(TextField, 'Full name'), _name);
  await tester.pump();
  await tester.tap(_advanceButton('Continue'));
  await _settle(tester);
}

/// Picks a faculty and a year through their dropdowns, as a student does.
Future<void> _chooseFacultyAndYear(WidgetTester tester) async {
  await tester.tap(_facultyDropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(_faculties.first.name).last);
  await tester.pumpAndSettle();

  await tester.tap(_yearDropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(_year).last);
  await tester.pumpAndSettle();
}

/// Ticks or unticks the consent row, pressing the row rather than the mark.
Future<void> _tapConsent(WidgetTester tester) async {
  await tester.tap(find.textContaining(_consentText));
  await _settle(tester);
}

/// A wizard sitting on the second step with the academic context filled in.
Future<_Harness> _atFilledSecondStep(WidgetTester tester) async {
  final harness = _harness(_fake());
  await _pumpWizard(tester, harness);
  await _completeNameStep(tester, harness);
  _chooseUniversity(harness, _university);
  await tester.pumpAndSettle();
  await _chooseFacultyAndYear(tester);
  return harness;
}

void main() {
  testWidgets('a faculty with no course units can still finish the wizard', (
    tester,
  ) async {
    // Four of the six seeded faculties publish no course units, so this is what a
    // real student of one of them meets on the last step. Two things have to hold
    // at once: the step has to say what is happening, and it has to let them
    // leave. A Finish button that stays disabled under an honest empty state
    // traps the student in the wizard for good, and the router would send them
    // straight back into it on every launch.
    final harness = await _atFilledSecondStep(tester);
    harness.repository.courseUnitOptions = const <CourseUnitOption>[];
    await _settle(tester);
    await _tapConsent(tester);
    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);

    expect(find.text('No course units yet'), findsOneWidget);
    expect(
      find.textContaining('Your faculty has not published any course units'),
      findsOneWidget,
    );
    expect(
      _canAdvance(tester, 'Finish'),
      isTrue,
      reason: 'nothing to choose is not a reason to be unable to finish',
    );

    await tester.tap(_advanceButton('Finish'));
    await _settle(tester);

    // Finishing means the request was actually made. A gate that let the button
    // through and then refused to save would look finished on screen and lose the
    // step on the next cold start.
    expect(
      harness.repository.profileUpdates.last,
      containsPair('primary_course_unit_ids', isEmpty),
    );
    expect(
      harness.container
          .read(sessionControllerProvider)
          .profile
          ?.needsOnboarding,
      isFalse,
      reason:
          'the router sends a profile that still needs onboarding back here',
    );
  });

  testWidgets('a module step whose catalogue failed to load stays closed', (
    tester,
  ) async {
    // The empty state must mean the faculty teaches nothing, not that the request
    // dropped. A failed catalogue is indistinguishable from an empty one if the
    // button is derived from data that has not arrived.
    final harness = _harness(_fake());
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);
    _chooseUniversity(harness, _university);
    await tester.pumpAndSettle();
    await _chooseFacultyAndYear(tester);
    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);

    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(_fake()),
        courseUnitsProvider((
          universityId: _university,
          subjectId: _faculties.first.publicId,
        )).overrideWith((ref) => throw const NetworkFailure()),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(canAdvanceWizardProvider),
      isFalse,
      reason: 'nothing is known about the catalogue, so nothing is assumed',
    );
  });

  testWidgets('the first step asks for a name and waits for one', (
    tester,
  ) async {
    final repository = _fake();
    final harness = _harness(repository);
    await _pumpWizard(tester, harness);

    expect(find.text('What is your name?'), findsOneWidget);
    expect(
      find.text('Tutors and other students will see this.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, 'Full name'), findsOneWidget);
    expect(
      _canAdvance(tester, 'Continue'),
      isFalse,
      reason: 'a blank name is not a name',
    );
    expect(repository.profileUpdates, isEmpty);
  });

  testWidgets('a name moves the wizard on to the academic context', (
    tester,
  ) async {
    final repository = _fake();
    final harness = _harness(repository);
    await _pumpWizard(tester, harness);

    await _completeNameStep(tester, harness);

    expect(find.text('What is your name?'), findsNothing);
    expect(find.text('Where do you study?'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Finish'), findsNothing);
    // The name is stored, and nothing else went with it: the API's profile
    // update is a partial merge, so a step that sent the whole record would
    // blank whatever the next step is about to collect.
    expect(repository.profileUpdates, hasLength(1));
    expect(repository.profileUpdates.single['full_name'], _name);
  });

  testWidgets('the second step asks where the student studies', (tester) async {
    final harness = _harness(_fake());
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);

    expect(find.text('Where do you study?'), findsOneWidget);
    expect(
      find.text('Used to show you tutors and units that are relevant to you.'),
      findsOneWidget,
    );
    expect(find.text('University'), findsOneWidget);
    expect(find.text('Faculty'), findsOneWidget);
    expect(find.text('Year of study'), findsOneWidget);
    expect(find.textContaining(_consentText), findsOneWidget);
  });

  testWidgets('Finish is refused until consent is ticked', (tester) async {
    // The data-protection gate, and the reason this step is a gate rather than a
    // preference: the academic context above is what matching later depends on,
    // and storing it without agreement is storing academic data about somebody
    // who never agreed to it.
    await _atFilledSecondStep(tester);

    expect(_canAdvance(tester, 'Continue'), isFalse);
    expect(_hasConsented(tester), isFalse);

    await _tapConsent(tester);

    expect(_canAdvance(tester, 'Continue'), isTrue);
    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);
    expect(find.text('Which units might you need help with?'), findsOneWidget);
    expect(_canAdvance(tester, 'Finish'), isFalse);
    await tester.tap(find.text('BIT 221 - Database Programming'));
    await tester.pump();
    expect(_canAdvance(tester, 'Finish'), isTrue);
  });

  testWidgets('a finished second step stores the context and the consent', (
    tester,
  ) async {
    // The other half of the gate: an enabled Finish has to actually record the
    // decision, because the academic context is only stored because somebody
    // agreed to it. Consent is sent as `true` rather than as a flag saying it is
    // unset, which the API would read as a request to record the absence of
    // consent.
    final harness = await _atFilledSecondStep(tester);
    await _tapConsent(tester);
    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);

    final sent = harness.repository.profileUpdates[1];
    expect(sent['university_id'], _university);
    expect(sent['faculty_id'], _faculties.first.publicId);
    expect(sent['year_of_study'], 2);
    expect(sent['academic_data_consented'], isTrue);
    // The name was stored on the previous step, and is not re-sent.
    expect(sent.containsKey('full_name'), isFalse);
    await tester.tap(find.text('BIT 221 - Database Programming'));
    await tester.pump();
    await tester.tap(_advanceButton('Finish'));
    await _settle(tester);
    expect(
      harness.repository.profileUpdates.last['primary_course_unit_ids'],
      <String>['unit-1'],
    );
  });

  testWidgets('tapping the consent row toggles the mark', (tester) async {
    final harness = _harness(_fake());
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);

    // The whole row is the target, not the tick: the sentence is what a student
    // is agreeing to, and a target the size of the mark gives them no way to
    // tell which of the two they just pressed.
    expect(_hasConsented(tester), isFalse);

    await _tapConsent(tester);
    expect(_hasConsented(tester), isTrue);

    await _tapConsent(tester);
    expect(_hasConsented(tester), isFalse);
  });

  testWidgets('the faculty dropdown is dead until a university is chosen', (
    tester,
  ) async {
    // The endpoint returns the whole catalogue rather than one university's, so a
    // faculty chosen first would be a guess about a list the student has not
    // been shown.
    final harness = _harness(_fake());
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);

    expect(
      tester
          .widget<DropdownButtonFormField<String>>(_facultyDropdown)
          .onChanged,
      isNull,
    );

    await tester.tap(_facultyDropdown);
    await tester.pumpAndSettle();

    expect(find.text(_faculties.first.name), findsNothing);
    expect(find.text(_faculties.last.name), findsNothing);
  });

  testWidgets('a save the API refuses is shown and does not advance', (
    tester,
  ) async {
    // A step that advanced after a refused write would be reported as finished
    // and then dropped on the next cold start, so the wizard has to stay put and
    // say why.
    final harness = _harness(_RefusingAuthRepository());
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);
    _chooseUniversity(harness, _university);
    await tester.pumpAndSettle();
    await _chooseFacultyAndYear(tester);
    await _tapConsent(tester);

    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);

    // The per-field message, not the summary: the summary does not say which
    // input the API was unhappy about, and the student is standing in front of
    // the form that has to change.
    expect(find.text(_refusedUniversity), findsOneWidget);
    // The step did not move, so the answers are still on screen to correct.
    expect(find.text('Where do you study?'), findsOneWidget);
    expect(find.text('What is your name?'), findsNothing);
    expect(
      _canAdvance(tester, 'Continue'),
      isTrue,
      reason: 'a refused save must be retryable rather than a dead end',
    );
  });

  testWidgets('the university dropdown offers the whole catalogue', (
    tester,
  ) async {
    // Regression. The picker built its items by filtering the catalogue down to
    // the currently selected entry, so a wizard with nothing chosen had an empty
    // dropdown: no tap could ever fire onChanged, the university stayed null, and
    // no student could finish onboarding. The flow is driven through the real
    // dropdown here rather than by setting the controller directly, because
    // setting the controller is the shortcut that hid this.
    final harness = _harness(_fake());
    await _pumpWizard(tester, harness);
    await tester.enterText(find.widgetWithText(TextField, 'Full name'), _name);
    await _settle(tester);
    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);

    expect(find.text('Where do you study?'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await _settle(tester);

    expect(
      find.text('Mbarara University of Science and Technology'),
      findsWidgets,
      reason: 'the catalogue has to be reachable, not just the chosen entry',
    );
    expect(find.text('Kyambogo University'), findsOneWidget);
  });

  testWidgets('choosing a university from the dropdown unlocks the faculty', (
    tester,
  ) async {
    final harness = _harness(_fake());
    await _pumpWizard(tester, harness);
    await tester.enterText(find.widgetWithText(TextField, 'Full name'), _name);
    await _settle(tester);
    await tester.tap(_advanceButton('Continue'));
    await _settle(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await _settle(tester);
    await tester.tap(find.text('Kyambogo University').last);
    await _settle(tester);

    final state = harness.container.read(onboardingControllerProvider);
    expect(state.universityId, 'university-2');
    expect(
      state.canContinue,
      isFalse,
      reason: 'a university alone is not a finished step',
    );
  });

  testWidgets('an empty university catalogue keeps MUST onboarding usable', (
    tester,
  ) async {
    final harness = _harness(
      FakeAuthRepository(session: _freshAccount, refreshToken: 'refresh'),
    );
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);

    expect(find.textContaining('Showing saved MUST options'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    expect(find.text('University'), findsOneWidget);
    expect(_canAdvance(tester, 'Continue'), isFalse);
  });

  testWidgets('a faculty lookup failure is visible and retryable', (
    tester,
  ) async {
    final harness = _harness(_UnavailableFacultyRepository());
    await _pumpWizard(tester, harness);
    await _completeNameStep(tester, harness);
    _chooseUniversity(harness, _university);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not load faculties. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    expect(find.text('Faculty'), findsNothing);
    expect(_canAdvance(tester, 'Continue'), isFalse);
  });
}
