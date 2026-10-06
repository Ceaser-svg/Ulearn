import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/models/academic_fallback.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/university_option.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';
import 'package:peerpass/features/auth/data/repositories/auth_repository.dart';
import 'package:peerpass/features/auth/data/repositories/fake_auth_repository.dart';
import 'package:peerpass/features/auth/presentation/providers/onboarding_providers.dart';
/// A student midway through the wizard: signed in, no name, no university. This
/// is the state the router hands to onboarding, and the state the fake merges
/// every partial update into.
const UserProfile _freshAccount = UserProfile(
  publicId: 'user-1',
  email: 'newcomer@must.ac.ug',
  roles: <UserRole>{UserRole.student},
);

const String _name = 'Achieng Okello';
const String _university = 'university-1';
const String _otherUniversity = 'university-2';
const String _faculty = 'subject-1';

/// A container wired to a fake repository, plus the fake so a test can read what
/// the wizard actually sent.
typedef _Harness = ({
  ProviderContainer container,
  FakeAuthRepository repository,
});

_Harness _harness() {
  final repository = FakeAuthRepository(
    session: _freshAccount,
    refreshToken: 'refresh',
  );
  final container = ProviderContainer(
    overrides: [authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);
  return (container: container, repository: repository);
}

/// Reads the wizard's state.
OnboardingState _state(ProviderContainer container) =>
    container.read(onboardingControllerProvider);

/// Drives the wizard.
OnboardingController _controller(ProviderContainer container) =>
    container.read(onboardingControllerProvider.notifier);

void main() {
  group('the name step', () {
    test('sends only the name, and advances', () async {
      // The API's profile update is a partial merge. A first step that sent the
      // whole record would blank a university the student had already chosen,
      // and a step that sent consent before the box was ticked would record
      // something the student never agreed to.
      final harness = _harness();
      _controller(harness.container).setFullName(_name);

      final advanced = await _controller(harness.container).saveAndAdvance();

      expect(advanced, isTrue);
      expect(_state(harness.container).step, OnboardingStep.academicContext);
      expect(harness.repository.profileUpdates, hasLength(1));
      final sent = harness.repository.profileUpdates.single;
      expect(sent['full_name'], _name);
      expect(sent.containsKey('university_id'), isFalse);
      expect(sent.containsKey('faculty_id'), isFalse);
      expect(sent.containsKey('year_of_study'), isFalse);
      expect(sent.containsKey('academic_data_consented'), isFalse);
    });

    test('trims the name before sending it', () async {
      // What is stored is what shows on a tutor's session screen. A trailing
      // space here is a name that never matches a search on the backend.
      final harness = _harness();
      _controller(harness.container).setFullName('  $_name   ');

      await _controller(harness.container).saveAndAdvance();

      expect(harness.repository.profileUpdates.single['full_name'], _name);
      expect(_state(harness.container).fullName, '  $_name   ');
    });

    test('sends nothing and does not advance when the name is blank', () async {
      // Whitespace is not a name. Advancing past this step would mark the
      // wizard as done with a field that is still empty, and the student would
      // land on home as an account that still needs onboarding.
      final harness = _harness();
      _controller(harness.container).setFullName('   ');

      final advanced = await _controller(harness.container).saveAndAdvance();

      expect(advanced, isFalse);
      expect(harness.repository.profileUpdates, isEmpty);
      expect(_state(harness.container).step, OnboardingStep.name);
    });

    test('canContinue is false until a name is typed', () {
      final harness = _harness();

      expect(_state(harness.container).canContinue, isFalse);
      _controller(harness.container).setFullName('A');
      expect(_state(harness.container).canContinue, isTrue);
    });
  });

  group('the academic context step', () {
    /// Advances to the second step, the way a student does by finishing the
    /// first one.
    Future<_Harness> atAcademicContext() async {
      final harness = _harness();
      _controller(harness.container).setFullName(_name);
      await _controller(harness.container).saveAndAdvance();
      harness.repository.profileUpdates.clear();
      return harness;
    }

    test('sends the academic context and the consent, and reports done', () async {
      // The last step returns true so the screen can hand over, and the router
      // then sends the student home because the profile no longer needs
      // onboarding. Consent travels with it because there is nowhere else for a
      // data-processing decision to be recorded.
      final harness = await atAcademicContext();
      _controller(harness.container)
        ..setUniversity(_university)
        ..setFaculty(_faculty)
        ..setYearOfStudy(2)
        ..setConsent(value: true);

      final advanced = await _controller(harness.container).saveAndAdvance();

      expect(advanced, isTrue);
      expect(_state(harness.container).saving, isFalse);
      final sent = harness.repository.profileUpdates.single;
      expect(sent['university_id'], _university);
      expect(sent['faculty_id'], _faculty);
      expect(sent['year_of_study'], 2);
      expect(sent['academic_data_consented'], isTrue);
      expect(sent.containsKey('full_name'), isFalse);
    });

    test('canContinue requires university, faculty, year and consent', () async {
      // All four are the precondition for a usable account: matching is scoped
      // to a university and its grading scale, and academic data may not be
      // processed without consent. The Next button is bound to this, so a
      // missing condition here is a student sent to a home screen with nothing
      // behind it.
      final harness = await atAcademicContext();

      _controller(harness.container)
        ..setUniversity(_university)
        ..setFaculty(_faculty)
        ..setYearOfStudy(2);
      expect(
        _state(harness.container).canContinue,
        isFalse,
        reason: 'consent ticked is the one thing still missing',
      );

      _controller(harness.container).setConsent(value: true);
      expect(_state(harness.container).canContinue, isTrue);
    });

    test('canContinue is false with any single field missing', () async {
      final complete = await atAcademicContext();
      _controller(complete.container)
        ..setUniversity(_university)
        ..setFaculty(_faculty)
        ..setYearOfStudy(2)
        ..setConsent(value: true);

      expect(_state(complete.container).canContinue, isTrue);

      final noFaculty = await atAcademicContext();
      _controller(noFaculty.container)
        ..setUniversity(_university)
        ..setYearOfStudy(2)
        ..setConsent(value: true);

      expect(_state(noFaculty.container).canContinue, isFalse);
    });

    test(
      'sends nothing and does not advance while consent is unticked',
      () async {
        final harness = await atAcademicContext();
        _controller(harness.container)
          ..setUniversity(_university)
          ..setFaculty(_faculty)
          ..setYearOfStudy(2);

        final advanced = await _controller(harness.container).saveAndAdvance();

        expect(advanced, isFalse);
        expect(harness.repository.profileUpdates, isEmpty);
      },
    );

    test('resolves fallback labels to live IDs before saving', () async {
      final harness = await atAcademicContext();
      harness.repository
        ..universityOptions = const [
          UniversityOption(
            publicId: _university,
            name: mustFallbackUniversityName,
          ),
        ]
        ..facultyOptions = const [
          Subject(publicId: _faculty, name: 'Faculty of Medicine'),
        ];
      _controller(harness.container)
        ..setUniversity(mustFallbackUniversityId)
        ..setFaculty(mustFallbackFaculties.first.publicId)
        ..setYearOfStudy(2)
        ..setConsent(value: true);

      final advanced = await _controller(harness.container).saveAndAdvance();

      expect(advanced, isTrue);
      expect(
        harness.repository.profileUpdates.single['university_id'],
        _university,
      );
      expect(harness.repository.profileUpdates.single['faculty_id'], _faculty);
      expect(_state(harness.container).universityId, _university);
      expect(_state(harness.container).facultyId, _faculty);
    });
  });

  group('university and faculty', () {
    test('changing the university clears the faculty', () {
      // The faculty belonged to the old university's catalogue. Carrying it
      // across would submit a faculty id that does not exist at the new one.
      final harness = _harness();
      _controller(harness.container)
        ..setUniversity(_university)
        ..setFaculty(_faculty)
        ..setUniversity(_otherUniversity);

      expect(_state(harness.container).universityId, _otherUniversity);
      expect(_state(harness.container).facultyId, isNull);
    });

    test('choosing the same university again keeps the faculty', () {
      // A picker re-emitting its current value is normal, and must not throw
      // away a choice the student already made.
      final harness = _harness();
      _controller(harness.container)
        ..setUniversity(_university)
        ..setFaculty(_faculty)
        ..setUniversity(_university);

      expect(_state(harness.container).facultyId, _faculty);
    });

    test('null is ignored rather than clearing the choice', () {
      final harness = _harness();
      _controller(harness.container)
        ..setUniversity(_university)
        ..setFaculty(_faculty)
        ..setUniversity(null)
        ..setFaculty(null);

      expect(_state(harness.container).universityId, _university);
      expect(_state(harness.container).facultyId, _faculty);
    });
  });

  group('back', () {
    test('returns from the academic context step to the name step', () async {
      // Going back must not lose the answers: the wizard is a draft until a
      // step is saved, and the student is still editing their own profile.
      final harness = _harness();
      _controller(harness.container).setFullName(_name);
      await _controller(harness.container).saveAndAdvance();

      _controller(harness.container).back();

      expect(_state(harness.container).step, OnboardingStep.name);
      expect(_state(harness.container).fullName, _name);
    });

    test('does nothing on the first step', () {
      final harness = _harness();
      _controller(harness.container).back();

      expect(_state(harness.container).step, OnboardingStep.name);
    });
  });

  group('double submission', () {
    test('a second save while one is in flight sends nothing extra', () async {
      // The button is disabled by `saving`, but a double tap can still land two
      // calls in the same frame. The second must be a no-op rather than a
      // second write for the same step.
      final harness = _harness();
      _controller(harness.container).setFullName(_name);

      final first = _controller(harness.container).saveAndAdvance();
      final second = _controller(harness.container).saveAndAdvance();
      final results = await Future.wait([first, second]);

      expect(results, <bool>[true, false]);
      expect(harness.repository.profileUpdates, hasLength(1));
    });
  });
}
