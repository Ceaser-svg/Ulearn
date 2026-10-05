import 'package:flutter_test/flutter_test.dart';
import 'package:peerpass/core/models/user_profile.dart';
import 'package:peerpass/core/models/user_role.dart';

/// A fully populated response body, as the API returns one for a student who has
/// finished onboarding.
const Map<String, dynamic> _completeBody = <String, dynamic>{
  'id': 'user-1',
  'email': 'achieng@must.ac.ug',
  'full_name': 'Achieng Okello',
  'roles': <String>['student'],
  'university_id': 'university-1',
  'faculty_id': 'subject-1',
  'year_of_study': 2,
  'academic_data_consented_at': '2026-01-15T09:30:00+00:00',
  'primary_course_unit_ids': <String>['unit-1'],
};

/// The complete body with one field swapped, as a test that varies a single
/// aspect of the response needs.
Map<String, dynamic> _bodyWith({List<String>? roles, num? yearOfStudy}) {
  return <String, dynamic>{
    ..._completeBody,
    'roles': ?roles,
    'year_of_study': ?yearOfStudy,
  };
}

void main() {
  group('UserProfile.fromJson', () {
    test('reads every field the API returns', () {
      final profile = UserProfile.fromJson(_completeBody);

      expect(profile.publicId, 'user-1');
      expect(profile.email, 'achieng@must.ac.ug');
      expect(profile.fullName, 'Achieng Okello');
      expect(profile.roles, <UserRole>{UserRole.student});
      expect(profile.universityId, 'university-1');
      expect(profile.facultyId, 'subject-1');
      expect(profile.yearOfStudy, 2);
      expect(profile.academicDataConsentedAt, DateTime.utc(2026, 1, 15, 9, 30));
      expect(profile.primaryCourseUnitIds, <String>['unit-1']);
    });

    test('reads the roles as a set, not as a wire list', () {
      // The API sends a JSON array whose order says nothing about meaning, so
      // anything built from it has to behave as a set.
      final profile = UserProfile.fromJson(
        _bodyWith(roles: const <String>['tutor', 'student']),
      );

      expect(profile.roles, <UserRole>{UserRole.student, UserRole.tutor});
      expect(profile.hasRole(UserRole.tutor), isTrue);
    });

    test('parses the body a brand-new account gets, with no optional fields', () {
      // Sign-up collects an address and a password, so this is the body a student
      // has on the very first frame after registering. A parser that demanded a
      // name or a university would crash the app at its most important moment.
      final profile = UserProfile.fromJson(const <String, dynamic>{
        'id': 'user-2',
        'email': 'newcomer@must.ac.ug',
        'roles': <String>['student'],
      });

      expect(profile.publicId, 'user-2');
      expect(profile.email, 'newcomer@must.ac.ug');
      expect(profile.roles, <UserRole>{UserRole.student});
      expect(profile.fullName, isNull);
      expect(profile.universityId, isNull);
      expect(profile.facultyId, isNull);
      expect(profile.yearOfStudy, isNull);
      expect(profile.academicDataConsentedAt, isNull);
    });

    test('drops a role it does not recognise and keeps the ones it does', () {
      // Forward compatibility. The pilot is still adding roles, and a new one
      // must show up as a student with fewer capabilities, not as a launch crash.
      final profile = UserProfile.fromJson(
        _bodyWith(
          roles: const <String>['student', 'department_chair', 'tutor'],
        ),
      );

      expect(profile.roles, <UserRole>{UserRole.student, UserRole.tutor});
    });

    test('reads a year of study sent as a JSON number', () {
      // JSON has one number type, so a year can arrive as a double. The model
      // owns a typed int and must do the narrowing itself.
      final profile = UserProfile.fromJson(_bodyWith(yearOfStudy: 3.0));

      expect(profile.yearOfStudy, 3);
      expect(profile.yearOfStudy, isA<int>());
    });
  });

  group('needsOnboarding', () {
    UserProfile profileWith({
      String? fullName = 'Achieng Okello',
      String? universityId = 'university-1',
      String? facultyId = 'faculty-1',
      List<String> primaryCourseUnitIds = const <String>['unit-1'],
    }) {
      return UserProfile(
        publicId: 'user-1',
        email: 'achieng@must.ac.ug',
        roles: const <UserRole>{UserRole.student},
        fullName: fullName,
        universityId: universityId,
        facultyId: facultyId,
        primaryCourseUnitIds: primaryCourseUnitIds,
      );
    }

    test('is false once a name, a university and a faculty are stored', () {
      expect(profileWith().needsOnboarding, isFalse);
    });

    test('is true when the name is missing', () {
      expect(profileWith(fullName: null).needsOnboarding, isTrue);
    });

    test('is true when the name is only whitespace', () {
      // The boundary a `fullName == null` check gets wrong: a student who tapped
      // the field and typed a space has a name on the wire, and must still be
      // held in the wizard.
      expect(profileWith(fullName: '   ').needsOnboarding, isTrue);
      expect(profileWith(fullName: '').needsOnboarding, isTrue);
    });

    test('is true when the university is missing', () {
      // A name alone is not a usable account: matching is scoped to a
      // university and its grading scale.
      expect(profileWith(universityId: null).needsOnboarding, isTrue);
    });

    test('is true when the faculty is missing', () {
      // A name and a university are not enough either. The course catalogue and
      // the tutor rail are both scoped to the faculty, so an account without one
      // is served an empty catalogue and would see an app full of nothing. The
      // faculty is step two of the wizard, so the gate can send it back.
      expect(profileWith(facultyId: null).needsOnboarding, isTrue);
    });

    test('is false with no declared course units', () {
      // The one gate that must not depend on this. Four of the six seeded
      // faculties publish no course units, so a student of one of them can never
      // declare any. Gating on a declared unit would send them back through the
      // wizard on every launch, for ever, with nothing they can do about it --
      // the wizard would be asking for something their faculty does not teach.
      // The module step still asks, and the course screens behind this gate
      // render their own empty state.
      expect(
        profileWith(primaryCourseUnitIds: const <String>[]).needsOnboarding,
        isFalse,
      );
    });
  });

  group('firstName', () {
    String? firstNameOf(String? fullName) {
      return UserProfile(
        publicId: 'user-1',
        email: 'achieng@must.ac.ug',
        roles: const <UserRole>{UserRole.student},
        fullName: fullName,
      ).firstName;
    }

    test('takes the first of two words', () {
      expect(firstNameOf('Achieng Okello'), 'Achieng');
    });

    test('is the whole name when there is one word', () {
      // Falling back to the whole word rather than guessing a split that may cut
      // a compound name in the wrong place.
      expect(firstNameOf('Prince'), 'Prince');
      expect(firstNameOf('van der Berg'), 'van');
    });

    test('is null when there is no name', () {
      expect(firstNameOf(null), isNull);
      expect(firstNameOf('   '), isNull);
    });

    test('trims the name before taking the first word', () {
      expect(firstNameOf('  Achieng Okello  '), 'Achieng');
      expect(firstNameOf(' Achieng   Okello '), 'Achieng');
    });
  });

  group('initials', () {
    String initialsOf(String? fullName) {
      return UserProfile(
        publicId: 'user-1',
        email: 'achieng@must.ac.ug',
        roles: const <UserRole>{UserRole.student},
        fullName: fullName,
      ).initials;
    }

    test('is the first letter of each of two words, upper-cased', () {
      expect(initialsOf('Achieng Okello'), 'AO');
      expect(initialsOf('achieng okello'), 'AO');
    });

    test('is the one letter for a single word', () {
      expect(initialsOf('Prince'), 'P');
    });

    test('is a question mark when there is no name to read', () {
      expect(initialsOf(null), '?');
      expect(initialsOf('   '), '?');
      expect(initialsOf(''), '?');
    });

    test('uses only the first two letters of a longer name', () {
      expect(initialsOf('Achieng Grace Okello'), 'AG');
    });

    test('ignores the extra spaces a pasted name arrives with', () {
      expect(initialsOf('  Achieng   Okello  '), 'AO');
    });
  });

  group('equality', () {
    const withRolesAb = UserProfile(
      publicId: 'user-1',
      email: 'achieng@must.ac.ug',
      roles: <UserRole>{UserRole.student, UserRole.tutor},
    );

    test('does not depend on the order the roles arrived in', () {
      // The API sends roles as a JSON list in no guaranteed order, so two
      // responses describing the same person must compare equal. Riverpod uses
      // this to decide whether to rebuild, and a list-order-sensitive compare
      // would rebuild the app on every refresh.
      const withRolesBa = UserProfile(
        publicId: 'user-1',
        email: 'achieng@must.ac.ug',
        roles: <UserRole>{UserRole.tutor, UserRole.student},
      );

      expect(withRolesAb, withRolesBa);
      expect(withRolesAb.hashCode, withRolesBa.hashCode);
    });

    test('separates profiles that differ in a stored field', () {
      expect(
        withRolesAb,
        isNot(
          const UserProfile(
            publicId: 'user-1',
            email: 'achieng@must.ac.ug',
            roles: <UserRole>{UserRole.student, UserRole.tutor},
            fullName: 'Achieng Okello',
          ),
        ),
      );
    });

    test('separates profiles that differ in their roles', () {
      expect(
        withRolesAb,
        isNot(
          const UserProfile(
            publicId: 'user-1',
            email: 'achieng@must.ac.ug',
            roles: <UserRole>{UserRole.student},
          ),
        ),
      );
    });
  });
}
