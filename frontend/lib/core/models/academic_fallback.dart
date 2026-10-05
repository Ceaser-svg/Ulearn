import 'package:peerpass/core/models/grade_option.dart';
import 'package:peerpass/core/models/subject.dart';
import 'package:peerpass/core/models/university_option.dart';

const mustFallbackUniversityId = 'fallback:must';

const mustFallbackUniversityName =
    'Mbarara University of Science and Technology';

const _facultyPrefix = 'fallback:must:faculty:';

const mustFallbackUniversity = UniversityOption(
  publicId: mustFallbackUniversityId,
  name: mustFallbackUniversityName,
  isFallback: true,
);

const mustFallbackFaculties = <Subject>[
  Subject(publicId: '${_facultyPrefix}medicine', name: 'Faculty of Medicine'),
  Subject(publicId: '${_facultyPrefix}science', name: 'Faculty of Science'),
  Subject(
    publicId: '${_facultyPrefix}computing',
    name: 'Faculty of Computing and Informatics Sciences',
  ),
  Subject(
    publicId: '${_facultyPrefix}applied',
    name: 'Faculty of Applied Sciences and Technology',
  ),
  Subject(
    publicId: '${_facultyPrefix}interdisciplinary',
    name: 'Faculty of Interdisciplinary Studies',
  ),
  Subject(
    publicId: '${_facultyPrefix}business',
    name: 'Faculty of Business and Management Sciences',
  ),
];

const mustFallbackGrades = <GradeOption>[
  GradeOption(publicId: 'fallback:must:grade:a', label: 'A', gradePoints: 5),
  GradeOption(
    publicId: 'fallback:must:grade:b-plus',
    label: 'B+',
    gradePoints: 4.5,
  ),
  GradeOption(publicId: 'fallback:must:grade:b', label: 'B', gradePoints: 4),
  GradeOption(
    publicId: 'fallback:must:grade:c-plus',
    label: 'C+',
    gradePoints: 3.5,
  ),
  GradeOption(publicId: 'fallback:must:grade:c', label: 'C', gradePoints: 3),
  GradeOption(
    publicId: 'fallback:must:grade:d-plus',
    label: 'D+',
    gradePoints: 2.5,
  ),
  GradeOption(publicId: 'fallback:must:grade:d', label: 'D', gradePoints: 2),
];

bool isMustFallbackUniversity(String? id) => id == mustFallbackUniversityId;

bool isMustFallbackGrade(String? id) =>
    id?.startsWith('fallback:must:grade:') ?? false;

String? mustFallbackFacultyName(String? id) {
  for (final faculty in mustFallbackFaculties) {
    if (faculty.publicId == id) return faculty.name;
  }
  return null;
}
