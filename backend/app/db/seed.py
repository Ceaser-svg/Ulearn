"""Reference data for the pilot institution.

Run it with `python -m app.db.seed`. Idempotent, so it is safe to re-run after a
migration.

The pilot is a single institution, so the seed holds a single university. It is
not filler: the onboarding wizard's pickers read these rows, and an empty
catalogue would leave those screens with nothing to show.

This is not a migration. Migrations move a schema between versions and are
written by hand; this fills tables whose contents are reference data, using the
tables the migrations already created.
"""

import asyncio
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_session_factory
from app.models.course_unit import CourseUnit, Program, Subject, University
from app.models.grading_scale import Grade, GradingScale

UNIVERSITY_NAME = "Mbarara University of Science and Technology"

#: MUST's undergraduate scale is a five-point scale, not a percentage one, and
#: the difference is load-bearing. A tutor's standing is stored as points, so a
#: percentage figure would put the number in the wrong unit twice over: in the
#: column, and in the comparison the matching engine makes.
SCALE_NAME = "MUST Undergraduate (5-point)"

#: The published maximum. `grades.max_points` is denormalised from this, which is
#: why a scale's maximum is treated as write-once once seeded.
MAX_POINTS = Decimal("5.00")

#: B+ is worth 4 points and is the bar a tutor must clear.
#:
#: Stored as data rather than as a constant in the matching code because the bar
#: belongs to the institution, not to the product. The next university added will
#: have its own, and changing one must not change another's.
#:
#: On MUST's published bands this is 65%, so B+ and everything above it
#: qualifies and B, at 55-64%, does not.
COMPETENCY_MIN_POINTS = Decimal("4.50")

#: A through D, best first.
#:
#: F is deliberately absent. `grades` carries a `grade_points > 0` check and F is
#: worth zero, so it cannot be represented on this scale without relaxing a
#: constraint the schema relies on. It is also not needed: a student's result is
#: a `Competency`, which asserts competence, and nobody claims competence with a
#: fail. Representing F belongs with transcript display, if that is ever built.
GRADES: tuple[tuple[str, str], ...] = (
    ("A", "5.00"),
    ("B+", "4.50"),
    ("B", "4.00"),
    ("C+", "3.50"),
    ("C", "3.00"),
    ("D+", "2.50"),
    ("D", "2.00"),
)

FACULTIES: tuple[tuple[str, str], ...] = (
    (
        "Faculty of Medicine",
        "The founding and most prominent faculty, offering health sciences "
        "undergraduate and postgraduate education.",
    ),
    (
        "Faculty of Science",
        "Focuses on basic and applied sciences, including biology, chemistry, "
        "mathematics, and physics.",
    ),
    (
        "Faculty of Computing and Informatics Sciences",
        "Drives technology education through computing, information technology, "
        "computer engineering, and postgraduate information systems programs.",
    ),
    (
        "Faculty of Applied Sciences and Technology",
        "Offers engineering and industrial programs, including biomedical, "
        "electrical and electronics, petroleum, and environmental programs.",
    ),
    (
        "Faculty of Interdisciplinary Studies",
        "Focuses on community development and applied interdisciplinary programs.",
    ),
    (
        "Faculty of Business and Management Sciences",
        "Provides business education tailored to science and technology sectors.",
    ),
)

PROGRAMS: tuple[tuple[str, str, str], ...] = (
    ("Faculty of Medicine", "undergraduate", "Medicine and Surgery (MBChB)"),
    ("Faculty of Medicine", "undergraduate", "Pharmacy"),
    ("Faculty of Medicine", "undergraduate", "Nursing Science"),
    ("Faculty of Medicine", "undergraduate", "Medical Laboratory Science"),
    ("Faculty of Medicine", "undergraduate", "Physiotherapy"),
    ("Faculty of Medicine", "postgraduate", "Master of Medicine (MMed)"),
    ("Faculty of Science", "undergraduate", "Bachelor of Science with Education"),
    ("Faculty of Science", "postgraduate", "MSc and PhD in Biology"),
    ("Faculty of Science", "postgraduate", "MSc and PhD in Chemistry"),
    ("Faculty of Science", "postgraduate", "MSc and PhD in Mathematics"),
    ("Faculty of Science", "postgraduate", "MSc and PhD in Physics"),
    (
        "Faculty of Computing and Informatics Sciences",
        "undergraduate",
        "Computer Science",
    ),
    (
        "Faculty of Computing and Informatics Sciences",
        "undergraduate",
        "Information Technology",
    ),
    (
        "Faculty of Computing and Informatics Sciences",
        "undergraduate",
        "Computer Engineering",
    ),
    (
        "Faculty of Computing and Informatics Sciences",
        "postgraduate",
        "Health Information Technology",
    ),
    (
        "Faculty of Computing and Informatics Sciences",
        "postgraduate",
        "Information Systems",
    ),
    (
        "Faculty of Applied Sciences and Technology",
        "undergraduate",
        "Biomedical Engineering",
    ),
    (
        "Faculty of Applied Sciences and Technology",
        "undergraduate",
        "Electrical and Electronics Engineering",
    ),
    (
        "Faculty of Applied Sciences and Technology",
        "undergraduate",
        "Petroleum Engineering",
    ),
    (
        "Faculty of Applied Sciences and Technology",
        "undergraduate",
        "Environmental Management",
    ),
    (
        "Faculty of Interdisciplinary Studies",
        "undergraduate",
        "Gender and Applied Women Health",
    ),
    (
        "Faculty of Interdisciplinary Studies",
        "undergraduate",
        "Planning and Community Development",
    ),
    (
        "Faculty of Interdisciplinary Studies",
        "undergraduate",
        "Agricultural Livelihoods",
    ),
    (
        "Faculty of Business and Management Sciences",
        "undergraduate",
        "Business Administration",
    ),
    (
        "Faculty of Business and Management Sciences",
        "undergraduate",
        "Accounting and Finance",
    ),
    (
        "Faculty of Business and Management Sciences",
        "undergraduate",
        "Procurement and Supply Chain Management",
    ),
)

#: The provisional MUST pilot catalogue: `(faculty, code, name)`.
#:
#: These are the only units currently eligible for the closed pilot. They are
#: seed entries, not an institutional endorsement or a claim that MUST's full
#: catalogue has been loaded. Do not derive more units from programme names:
#: programmes and matchable course units are different records.
#:
#: Every faculty MUST publishes has at least one unit here. A faculty with an
#: empty catalogue cannot be declared against, so a student in one could never
#: apply to tutor -- the pilot would look like a broken feature rather than an
#: empty one. `tests/test_cli.py` fails if a faculty is added without a unit.
#:
#: **The codes are provisional and are not MUST course codes.** MUST does not
#: publish a course-unit catalogue: `must.ac.ug` programme pages carry faculty,
#: course code, duration and entry requirements, but their "Course Modules" tab
#: is empty, and no module list is published anywhere public. The names below
#: are drawn from MUST's own academic units -- the departments listed on each
#: faculty page -- because a department is a real, verifiable academic unit
#: where a programme name is not, and its subject areas are what its first-year
#: courses teach. Replace the whole table with the official catalogue when MUST
#: supplies one; nothing else in the codebase encodes a code or a name.
#:
#: Sources, retrieved for this seed:
#:
#: * `must.ac.ug/university_unit/faculty-of-medicine` and its Biochemistry
#:   department page, which states biochemistry is "a mandatory course for all
#:   students in the faculty".
#: * `must.ac.ug/university_unit/faculty-of-applied-sciences-and-technology`,
#:   which lists the Department of Electrical and Electronic Engineering, and the
#:   BEEE programme page, whose entry requirements name Technical Drawing.
#: * `must.ac.ug/university_unit/faculty-of-business-and-management-sciences`,
#:   which lists the Departments of Accounting and Finance and of Economics and
#:   Entrepreneurship.
#: * `must.ac.ug/university_unit/faculty-of-interdisciplinary-studies`, which
#:   lists its four departments by name.
#:
#: Note that MUST's own site now calls this faculty "Faculty of Health Sciences"
#: and lists a seventh faculty, Agriculture, Environment and Veterinary Sciences.
#: The seed keeps the older names because renaming a seeded faculty would orphan
#: every course unit, declared module and competency keyed to it.
COURSE_UNITS: tuple[tuple[str, str, str], ...] = (
    ("Faculty of Computing and Informatics Sciences", "BIT 221", "Operating Systems"),
    (
        "Faculty of Computing and Informatics Sciences",
        "BIT 223",
        "Database Programming",
    ),
    ("Faculty of Computing and Informatics Sciences", "BIT 225", "Computer Networks"),
    ("Faculty of Science", "SCH 211", "Organic Chemistry"),
    ("Faculty of Science", "PHY 212", "Thermodynamics"),
    ("Faculty of Science", "MTH 213", "Linear Algebra"),
    ("Faculty of Medicine", "MED 211", "Human Anatomy"),
    ("Faculty of Medicine", "MED 212", "Human Physiology"),
    ("Faculty of Medicine", "MED 213", "Medical Biochemistry"),
    ("Faculty of Applied Sciences and Technology", "AST 211", "Electrical Circuits"),
    ("Faculty of Applied Sciences and Technology", "AST 212", "Electronics"),
    ("Faculty of Applied Sciences and Technology", "AST 213", "Engineering Drawing"),
    ("Faculty of Business and Management Sciences", "BMS 211", "Financial Accounting"),
    (
        "Faculty of Business and Management Sciences",
        "BMS 212",
        "Principles of Economics",
    ),
    (
        "Faculty of Business and Management Sciences",
        "BMS 213",
        "Entrepreneurship",
    ),
    ("Faculty of Interdisciplinary Studies", "IDS 211", "Planning and Governance"),
    (
        "Faculty of Interdisciplinary Studies",
        "IDS 212",
        "Human Development and Relational Sciences",
    ),
    (
        "Faculty of Interdisciplinary Studies",
        "IDS 213",
        "Community Engagement and Service Learning",
    ),
)


async def _seed_grading_scale(db: AsyncSession) -> GradingScale:
    """MUST's scale and its grade catalogue, created if absent."""
    scale = await db.scalar(select(GradingScale).where(GradingScale.name == SCALE_NAME))
    if scale is None:
        scale = GradingScale(
            name=SCALE_NAME,
            max_points=MAX_POINTS,
            competency_min_points=COMPETENCY_MIN_POINTS,
        )
        db.add(scale)
        await db.flush()

    present = set(
        (
            await db.execute(
                select(Grade.label).where(Grade.grading_scale_id == scale.id)
            )
        ).scalars()
    )
    for label, points in GRADES:
        if label not in present:
            db.add(
                Grade(
                    label=label,
                    grade_points=Decimal(points),
                    max_points=MAX_POINTS,
                    grading_scale_id=scale.id,
                )
            )
    await db.flush()
    return scale


async def _seed_subjects(db: AsyncSession) -> dict[str, Subject]:
    """The faculties, keyed by name, with any missing ones added."""
    subjects = {
        row.name: row
        for row in (
            await db.execute(select(Subject).where(Subject.university_id.is_(None)))
        ).scalars()
    }
    for name, description in FACULTIES:
        subject = subjects.get(name)
        if subject is None:
            subject = Subject(
                name=name,
                description=description,
            )
            db.add(subject)
            subjects[name] = subject
        else:
            subject.description = description
    await db.flush()
    return subjects


async def _seed_university(db: AsyncSession, scale: GradingScale) -> University:
    """MUST, attached to the scale its grades are awarded on."""
    university = await db.scalar(
        select(University).where(University.name == UNIVERSITY_NAME)
    )
    if university is None:
        university = University(name=UNIVERSITY_NAME, grading_scale_id=scale.id)
        db.add(university)
        await db.flush()
    return university


async def _seed_course_units(
    db: AsyncSession, university: University, subjects: dict[str, Subject]
) -> tuple[int, list[str]]:
    """The starting catalogue. Returns the count added and any unmatched faculties."""
    present = set(
        (
            await db.execute(
                select(CourseUnit.code).where(CourseUnit.university_id == university.id)
            )
        ).scalars()
    )

    added = 0
    orphans: set[str] = set()
    for faculty, code, name in COURSE_UNITS:
        if code in present:
            continue
        subject = subjects.get(faculty)
        if subject is None:
            orphans.add(faculty)
        db.add(
            CourseUnit(
                code=code,
                name=name,
                university_id=university.id,
                subject_id=subject.id if subject is not None else None,
                # `grade_id` is left null deliberately. A unit awards a range of
                # grades, not one, and the grade a student actually got is named
                # by their `Competency`. Assigning a single grade to every unit
                # would invent data that the model already has a correct place
                # for. The unit's scale is inherited from its university either
                # way, which is what the matching engine reads.
                grade_id=None,
            )
        )
        added += 1
    await db.flush()
    return added, sorted(orphans)


async def _seed_programs(
    db: AsyncSession,
    university: University,
    subjects: dict[str, Subject],
) -> int:
    """Seed MUST's faculty programs without turning them into course units."""
    added = 0
    for faculty_name, level, name in PROGRAMS:
        subject = subjects[faculty_name]
        existing = await db.scalar(
            select(Program).where(
                Program.university_id == university.id,
                Program.faculty_id == subject.id,
                Program.name == name,
            )
        )
        if existing is None:
            db.add(
                Program(
                    name=name,
                    level=level,
                    university_id=university.id,
                    faculty_id=subject.id,
                )
            )
            added += 1
    await db.flush()
    return added


async def seed(db: AsyncSession) -> None:
    """Fill in the pilot's reference data and report what it did."""
    scale = await _seed_grading_scale(db)
    subjects = await _seed_subjects(db)
    university = await _seed_university(db, scale)
    for subject in subjects.values():
        subject.university_id = university.id
    await db.flush()
    added, orphans = await _seed_course_units(db, university, subjects)
    programs_added = await _seed_programs(db, university, subjects)
    await db.commit()

    print(f"Seeded {UNIVERSITY_NAME}")
    print(
        f"  grading scale : {SCALE_NAME} "
        f"(max {MAX_POINTS}, gate {COMPETENCY_MIN_POINTS})"
    )
    print(f"  grades        : {', '.join(label for label, _ in GRADES)}")
    print(f"  faculties     : {len(subjects)}")
    print(f"  programs      : {programs_added} added")
    print(f"  course units  : {added} added")
    if orphans:
        # Loud rather than silent: a unit with no faculty is invisible in the
        # wizard's faculty filter, which looks like a bug from the student's
        # side and has no other symptom.
        print(f"  WARNING: no faculty row for {', '.join(orphans)}")


def main() -> None:
    """Entry point for `python -m app.db.seed`."""

    async def _run() -> None:
        async with get_session_factory()() as session:
            await seed(session)

    asyncio.run(_run())


if __name__ == "__main__":
    main()
