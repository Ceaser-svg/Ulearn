"""Matching: who the platform is willing to propose, and why not the others.

Two layers, deliberately. The service tests state the gate as a rule -- this
grade is in, that one is out, this standing is proposed -- and they call the
service directly, because a rule reachable only through a router is a rule
nobody can read.

The wire tests go through the real router with a real token, because two of the
defects this file now covers are invisible to a service test. One handler was
registered at two URLs, so which one a client reached depended on the base URL
it was configured with. And the request-backed route answered for whichever
course unit the *body* carried, ignoring the request in its own path -- a tutor
who could help with something else entirely was the answer to "who can take
this request". Both look correct from the service, which is the point of
asserting them over HTTP.
"""

from contextlib import contextmanager
from decimal import Decimal

import pytest
from sqlalchemy import event, select

from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Subject, University
from app.models.enums import (
    CompetencyStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade, GradingScale
from app.models.tutor_profile import TutorProfile
from app.models.user import User, set_roles
from app.schemas.matching import MATCH_EXCLUSION_REASONS, MatchRequest
from app.schemas.session import HelpRequestCreate
from app.services import matching_service
from tests.support import sole_faculty_id

GOOD_PASSWORD = "correct horse battery staple"


async def _seed_match_data(db_session):
    scale = GradingScale(
        name="Makerere 5-point",
        max_points=Decimal("5.00"),
        competency_min_points=Decimal("4.00"),
    )
    university = University(name="Makerere University", grading_scale=scale)
    subject = Subject(name="Computer Science")
    grade = Grade(
        label="A",
        grade_points=Decimal("4.50"),
        max_points=Decimal("5.00"),
        grading_scale=scale,
    )
    course_unit = CourseUnit(
        code="CSC 121",
        name="Algorithms",
        subject=subject,
        university=university,
        grade=grade,
    )
    student = User(
        email="student@mak.ac.ug",
        password_hash="hashed-password",
        full_name="Student Example",
        university=university,
        faculty=subject,
    )
    tutor = User(
        email="tutor@mak.ac.ug",
        password_hash="hashed-password",
        full_name="Tutor Example",
        university=university,
        faculty=subject,
    )
    tutor_profile = TutorProfile(
        user=tutor,
        standing=TutorStanding.VERIFIED,
        completed_sessions=12,
        rating_total=Decimal("42.00"),
        rating_count=10,
    )
    competency = Competency(
        user=tutor,
        course_unit=course_unit,
        grade=grade,
        status=CompetencyStatus.VERIFIED,
        source=VerificationSource.TRANSCRIPT,
    )

    db_session.add_all(
        [
            scale,
            university,
            subject,
            grade,
            course_unit,
            student,
            tutor,
            tutor_profile,
            competency,
        ]
    )
    await db_session.flush()
    await set_roles(db_session, tutor.id, {UserRole.TUTOR})
    await db_session.commit()
    return student, tutor, course_unit


async def test_create_help_request_and_match_tutors(db_session):
    student, _tutor, course_unit = await _seed_match_data(db_session)

    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(
            course_unit_id=course_unit.public_id,
            topic="quick sort",
            description="Need help understanding partitions.",
        ),
    )
    response = await matching_service.match_tutors(
        db_session,
        student,
        MatchRequest(course_unit_id=course_unit.public_id, limit=5),
    )

    assert request.course_unit_id == course_unit.public_id
    assert response.no_eligible_tutors is False
    assert response.candidates
    assert response.candidates[0].tutor.full_name == "Tutor Example"


async def test_tutor_from_other_university_is_excluded(db_session):
    home_scale = GradingScale(
        name="Home scale",
        max_points=Decimal("5.00"),
        competency_min_points=Decimal("4.00"),
    )
    home_university = University(name="Home University", grading_scale=home_scale)
    other_university = University(name="Other University", grading_scale=home_scale)
    subject = Subject(name="Mathematics")
    grade = Grade(
        label="A",
        grade_points=Decimal("4.50"),
        max_points=Decimal("5.00"),
        grading_scale=home_scale,
    )
    course_unit = CourseUnit(
        code="MTH 101",
        name="Calculus",
        subject=subject,
        university=home_university,
        grade=grade,
    )
    student = User(
        email="student@home.ac.ug",
        password_hash="hashed-password",
        full_name="Student Example",
        university=home_university,
        faculty=subject,
    )
    tutor = User(
        email="tutor@other.ac.ug",
        password_hash="hashed-password",
        full_name="Other Tutor",
        university=other_university,
        faculty=subject,
    )
    db_session.add_all(
        [
            home_scale,
            home_university,
            other_university,
            subject,
            grade,
            course_unit,
            student,
            tutor,
        ]
    )
    await db_session.flush()
    await set_roles(db_session, tutor.id, {UserRole.TUTOR})
    db_session.add(
        TutorProfile(
            user=tutor,
            standing=TutorStanding.VERIFIED,
            completed_sessions=7,
            rating_total=Decimal("30.00"),
            rating_count=7,
        )
    )
    db_session.add(
        Competency(
            user=tutor,
            course_unit=course_unit,
            grade=grade,
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    await db_session.commit()

    response = await matching_service.match_tutors(
        db_session,
        student,
        MatchRequest(course_unit_id=course_unit.public_id, limit=5),
    )

    assert response.no_eligible_tutors is True
    assert any(item.reason == "same_university_only" for item in response.exclusions)


# --- fixtures for the cases below -------------------------------------------
#
# `_seed_match_data` above is left exactly as it was: the two cases it serves are
# the original ones and rewriting their fixture would make the diff say more than
# the change does. These build the harder states -- a scale with a grade on each
# side of the bar, a tutor at another institution, a tutor the platform holds a
# verified grade for and no standing for.


async def _campus(
    db_session,
    *,
    name: str = "Makerere University",
    subject_name: str = "Computer Science",
    codes: tuple[str, ...] = ("CSC 121",),
) -> tuple[University, dict[str, Grade], dict[str, CourseUnit]]:
    """A university whose scale gates competency at B+, with a grade either side.

    `B+` sits at exactly `competency_min_points` and `B` below it, so the gate
    has an unambiguous in and an unambiguous out. A fixture offering only a grade
    that clears the bar tests the happy path and says nothing about where the bar
    is, which is the one thing about a grade gate a reader wants stated.
    """
    scale = GradingScale(
        name=f"{name} scale",
        max_points=Decimal("5.00"),
        competency_min_points=Decimal("4.00"),
    )
    university = University(name=name, grading_scale=scale)
    subject = Subject(name=subject_name)
    grades = {
        label: Grade(
            label=label,
            grade_points=Decimal(points),
            max_points=Decimal("5.00"),
            grading_scale=scale,
        )
        for label, points in (("A", "5.00"), ("B+", "4.00"), ("B", "3.50"))
    }
    units = {
        code: CourseUnit(
            code=code,
            name=f"Unit {code}",
            subject=subject,
            university=university,
            grade=grades["A"],
        )
        for code in codes
    }
    db_session.add_all([scale, university, subject, *grades.values(), *units.values()])
    await db_session.flush()
    return university, grades, units


async def _student(
    db_session,
    university: University,
    *,
    email: str = "student@mak.ac.ug",
    full_name: str = "Student Example",
) -> User:
    """A signed-up student at `university`, with no roles granted."""
    user = User(
        email=email,
        password_hash="hashed-password",
        full_name=full_name,
        university=university,
        faculty_id=await sole_faculty_id(db_session, university),
    )
    db_session.add(user)
    await db_session.flush()
    return user


async def _competent_tutor(
    db_session,
    *,
    university: University,
    units: list[CourseUnit],
    grade: Grade,
    email: str,
    full_name: str,
    status: CompetencyStatus = CompetencyStatus.VERIFIED,
    standing: TutorStanding = TutorStanding.VERIFIED,
    profile: bool = True,
) -> User:
    """A tutor: the role, a profile unless refused one, one competency per unit.

    `profile=False` is a state the platform can reach -- a role granted by a path
    that does not create the row, or a row deleted out from under a tutor -- and
    matching has to have an answer for it. Every tutor here is given the role
    explicitly, because the search joins `user_roles`: a user with a verified
    grade and no role is not a tutor at all and is never even considered.
    """
    # A tutor is placed in the faculty of the units they teach, rather than looked
    # up: it is the same answer by construction, and it cannot drift from the units
    # a test is about to match on. Asserted rather than assumed, because a fixture
    # handed units from two faculties has no single correct faculty to pick.
    subjects = {unit.subject_id for unit in units}
    assert len(subjects) == 1, (
        "a tutor belongs to one faculty, so the units handed here must share one"
    )
    user = User(
        email=email,
        password_hash="hashed-password",
        full_name=full_name,
        university=university,
        faculty_id=subjects.pop(),
    )
    db_session.add(user)
    if profile:
        db_session.add(
            TutorProfile(
                user=user,
                standing=standing,
                completed_sessions=6,
                rating_total=Decimal("36.00"),
                rating_count=10,
            )
        )
    for unit in units:
        db_session.add(
            Competency(
                user=user,
                course_unit=unit,
                grade=grade,
                status=status,
                source=VerificationSource.TRANSCRIPT,
            )
        )
    await db_session.flush()
    await set_roles(db_session, user.id, {UserRole.TUTOR})
    return user


def _reasons(response) -> dict[object, list[str]]:
    """Exclusions keyed by tutor, so a test can read one tutor's whole story."""
    grouped: dict[object, list[str]] = {}
    for exclusion in response.exclusions:
        grouped.setdefault(exclusion.tutor_id, []).append(exclusion.reason)
    return grouped


async def _match_for(
    db_session,
    student: User,
    unit: CourseUnit,
    **overrides,
):
    payload = MatchRequest(course_unit_id=unit.public_id, **overrides)
    return await matching_service.match_tutors(db_session, student, payload)


# --- the gate ----------------------------------------------------------------


async def test_the_grade_boundary_is_inclusive(db_session):
    """B+ is in and B is out, which means the comparison is `>=`.

    The boundary is stated rather than the neighbourhood: a gate written as `>`
    would pass every one of these cases and refuse the single most common grade
    a tutor holds, and the only way to tell the two apart is to put a tutor
    exactly on the number.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    at_the_bar = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B+"],
        email="at-the-bar@mak.ac.ug",
        full_name="At The Bar",
    )
    below = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B"],
        email="below-bar@mak.ac.ug",
        full_name="Below Bar",
    )
    await db_session.commit()

    response = await _match_for(db_session, student, units["CSC 121"])

    assert [item.tutor.user_id for item in response.candidates] == [
        at_the_bar.public_id
    ]
    assert _reasons(response) == {below.public_id: ["below_threshold"]}
    assert response.no_eligible_tutors is False


@pytest.mark.parametrize(
    "status", [CompetencyStatus.PENDING, CompetencyStatus.REJECTED]
)
async def test_a_grade_nobody_signed_off_is_reported_as_unverified(db_session, status):
    """The reason is the check, not the number.

    An A is above the bar, so a `below_threshold` here would tell a tutor with
    an unverified A that their problem was the grade. Both unverified states are
    covered because a tutor reads them differently -- one is "awaiting review",
    the other is "refused" -- and neither of them is eligible.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    unchecked = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        status=status,
        email=f"unchecked-{status.value}@mak.ac.ug",
        full_name="Unchecked Tutor",
    )
    await db_session.commit()

    response = await _match_for(db_session, student, units["CSC 121"])

    assert response.candidates == []
    assert response.no_eligible_tutors is True
    assert _reasons(response) == {unchecked.public_id: ["unverified"]}


async def test_a_competency_in_another_unit_is_not_a_candidate(db_session):
    """The wrong unit is not a weaker candidate, it is no candidate.

    Stated explicitly because "wrong unit" is the failure a widened search is most
    likely to introduce, and a tutor strong in a sibling unit must not appear in
    the answer for this one.
    """
    university, grades, units = await _campus(db_session, codes=("CSC 121", "CSC 122"))
    student = await _student(db_session, university)
    elsewhere_qualified = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="other-unit@mak.ac.ug",
        full_name="Other Unit Tutor",
    )
    await db_session.commit()

    response = await _match_for(db_session, student, units["CSC 121"])

    assert response.candidates == []
    assert elsewhere_qualified.public_id not in _reasons(response), (
        "a tutor with no competency for this unit is not 'ruled out' by anything"
    )


async def test_a_provisional_tutor_is_proposed_and_ranked_below_a_verified_one(
    db_session,
):
    """Provisional is a ranking input, not a disqualification.

    Invariant 3: a tutor starts Provisional and is promoted by ratings. Reading
    Provisional as ineligible would make the first session unreachable, and no
    tutor would ever earn the Verified standing that reading requires. Only
    `SUSPENDED` is excluded, so the difference between the two standings is
    asserted as an order rather than as a presence.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    provisional = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="provisional@mak.ac.ug",
        full_name="Provisional Tutor",
        standing=TutorStanding.PROBATIONARY,
    )
    verified = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="verified@mak.ac.ug",
        full_name="Verified Tutor",
        standing=TutorStanding.VERIFIED,
    )
    await db_session.commit()

    response = await _match_for(db_session, student, units["CSC 121"])

    assert [item.tutor.user_id for item in response.candidates] == [
        verified.public_id,
        provisional.public_id,
    ]
    assert response.exclusions == []


async def test_the_caller_is_not_proposed_for_their_own_request(db_session):
    """A student who also tutors does not answer their own request.

    Filtered in the query rather than reported as an exclusion, and the
    difference is deliberate: they were never a candidate, so telling them they
    were "ruled out" would be a statement about them rather than about the rule.
    """
    university, grades, units = await _campus(db_session)
    caller = await _student(db_session, university, email="both@mak.ac.ug")
    db_session.add(
        TutorProfile(
            user=caller,
            standing=TutorStanding.VERIFIED,
            rating_total=Decimal("45.00"),
            rating_count=10,
        )
    )
    db_session.add(
        Competency(
            user=caller,
            course_unit=units["CSC 121"],
            grade=grades["A"],
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    await db_session.flush()
    await set_roles(db_session, caller.id, {UserRole.STUDENT, UserRole.TUTOR})
    other = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="other@mak.ac.ug",
        full_name="Other Tutor",
    )
    await db_session.commit()

    response = await _match_for(db_session, caller, units["CSC 121"])

    assert [item.tutor.user_id for item in response.candidates] == [other.public_id]
    assert caller.public_id not in _reasons(response)


async def test_every_advertised_exclusion_code_is_reachable(db_session):
    """`MATCH_EXCLUSION_REASONS` and the codes the engine emits are the same set.

    A documented reason nothing produces is worse than a missing one: a client
    writes a branch for it, that branch never fires, and a tutor with a real,
    fixable problem is told the platform has no reason. So this asserts equality
    in both directions, over a university built to produce all five at once.
    """
    home, home_grades, units = await _campus(db_session)
    away, _away_grades, _away_units = await _campus(
        db_session,
        name="Ndejje University",
        subject_name="Ndejje Mathematics",
    )
    student = await _student(db_session, home, email="all-codes@mak.ac.ug")

    suspended = await _competent_tutor(
        db_session,
        university=home,
        units=[units["CSC 121"]],
        grade=home_grades["A"],
        email="suspended@mak.ac.ug",
        full_name="Suspended Tutor",
        standing=TutorStanding.SUSPENDED,
    )
    profileless = await _competent_tutor(
        db_session,
        university=home,
        units=[units["CSC 121"]],
        grade=home_grades["A"],
        email="profileless@mak.ac.ug",
        full_name="Profileless Tutor",
        profile=False,
    )
    below = await _competent_tutor(
        db_session,
        university=home,
        units=[units["CSC 121"]],
        grade=home_grades["B"],
        email="below@mak.ac.ug",
        full_name="Below Tutor",
    )
    unchecked = await _competent_tutor(
        db_session,
        university=home,
        units=[units["CSC 121"]],
        grade=home_grades["A"],
        status=CompetencyStatus.PENDING,
        email="unchecked@mak.ac.ug",
        full_name="Unchecked Tutor",
    )
    foreign = await _competent_tutor(
        db_session,
        university=away,
        units=[units["CSC 121"]],
        grade=home_grades["A"],
        email="foreign@mak.ac.ug",
        full_name="Foreign Tutor",
    )
    await db_session.commit()

    response = await _match_for(db_session, student, units["CSC 121"])

    assert _reasons(response) == {
        suspended.public_id: ["suspended"],
        profileless.public_id: ["not_the_tutor"],
        below.public_id: ["below_threshold"],
        unchecked.public_id: ["unverified"],
        foreign.public_id: ["same_university_only"],
    }
    assert {
        reason for reasons in _reasons(response).values() for reason in reasons
    } == set(MATCH_EXCLUSION_REASONS)
    assert response.candidates == []
    assert response.no_eligible_tutors is True


# --- one row per tutor, and the same row every time --------------------------


async def test_a_widened_search_returns_one_row_per_tutor_keeping_their_best_unit(
    db_session,
):
    """A tutor competent in three units is one suggestion, not three.

    Listed once with their strongest qualifying unit, because the page is a
    shortlist a student chooses from and a tutor repeated three times pushes
    three weaker tutors off it. Their weakest unit is below the bar rather than
    missing, so the unit that cannot be proposed is visible as an exclusion
    instead of vanishing.

    The two eligible units are built to tie on everything a candidate carries --
    same grade, same score, same tutor -- so the unit kept is decided by the
    course **code**, `CSC 121` before `CSC 122`. A public id would decide it too,
    at random: deterministic, and meaningless, which is a worse thing for a
    student-facing list to be.
    """
    university, grades, units = await _campus(
        db_session, codes=("CSC 121", "CSC 122", "CSC 123")
    )
    student = await _student(db_session, university)
    tutor = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"], units["CSC 122"]],
        grade=grades["A"],
        email="widespread@mak.ac.ug",
        full_name="Widespread Tutor",
    )
    # The same tutor, in the target unit, below the bar.
    db_session.add(
        Competency(
            user=tutor,
            course_unit=units["CSC 123"],
            grade=grades["B"],
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    await db_session.commit()

    response = await _match_for(
        db_session, student, units["CSC 123"], widen_to_subject=True
    )

    assert response.widened is True
    assert [
        (item.tutor.user_id, item.course_unit_id) for item in response.candidates
    ] == [(tutor.public_id, units["CSC 121"].public_id)]
    # Asked for twice, because "the first row the query happened to return" is an
    # order that changes with the plan rather than with the data.
    again = await _match_for(
        db_session, student, units["CSC 123"], widen_to_subject=True
    )
    assert [item.course_unit_id for item in again.candidates] == [
        item.course_unit_id for item in response.candidates
    ]


async def test_an_exact_match_never_widens(db_session):
    """`widened` is a fallback, and the report says whether it was taken.

    A client showing "we widened your search" when it did not would send a
    student looking for a reason the tutor cannot help with the exact course,
    which is the reason the widening is opt-in at all.
    """
    university, grades, units = await _campus(db_session, codes=("CSC 121", "CSC 122"))
    student = await _student(db_session, university)
    await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="exact@mak.ac.ug",
        full_name="Exact Tutor",
    )
    await db_session.commit()

    response = await _match_for(
        db_session, student, units["CSC 121"], widen_to_subject=True
    )

    assert response.widened is False
    assert len(response.candidates) == 1


@contextmanager
def _counting_statements(db_engine):
    """Count the statements an engine actually sends.

    Round trips, not rows: the question is whether the search asks the database
    again per competency, which is invisible in the result set and only visible
    in the count.
    """
    counter = {"count": 0}

    def _record(conn, cursor, statement, parameters, context, executemany):
        counter["count"] += 1

    event.listen(db_engine.sync_engine, "before_cursor_execute", _record)
    try:
        yield counter
    finally:
        event.remove(db_engine.sync_engine, "before_cursor_execute", _record)


async def test_the_search_does_not_ask_the_database_once_per_row(db_session, db_engine):
    """Four times the tutors, the same number of round trips.

    The tutor role used to be resolved with one query per competency, so a
    widened search across a large subject cost a round trip per row before
    producing the answer a single join gives. The result set cannot show that --
    both versions return the same tutors -- so the assertion is on the statement
    count with one tutor and then with four, and it has to be unchanged.
    """
    university, grades, units = await _campus(db_session, codes=("CSC 121", "CSC 122"))
    student = await _student(db_session, university)
    await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="first@mak.ac.ug",
        full_name="First Tutor",
    )
    await db_session.commit()

    with _counting_statements(db_engine) as counter:
        one = await _match_for(
            db_session, student, units["CSC 121"], widen_to_subject=True
        )
    assert len(one.candidates) == 1
    with_one = counter["count"]

    for index in range(3):
        await _competent_tutor(
            db_session,
            university=university,
            units=[units["CSC 122"]],
            grade=grades["A"],
            email=f"more-{index}@mak.ac.ug",
            full_name=f"More Tutor {index}",
        )
    await db_session.commit()

    with _counting_statements(db_engine) as counter:
        four = await _match_for(
            db_session, student, units["CSC 121"], widen_to_subject=True
        )

    assert len(four.candidates) == 4
    assert counter["count"] == with_one


# --- the wire ---------------------------------------------------------------
#
# Registering through the router is the only way to get a row with a usable
# password hash and a live access token; the university is set directly because
# `PATCH /v1/users/me` has its own tests and these cases are about matching.


async def _account(
    client,
    db_session,
    email: str,
    *,
    full_name: str | None = None,
    university: University | None = None,
) -> tuple[dict, User]:
    response = await client.post(
        "/v1/auth/register", json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 201, response.text
    body = response.json()
    user = await db_session.scalar(select(User).where(User.email == email))
    assert user is not None
    if full_name is not None:
        user.full_name = full_name
    if university is not None:
        user.university_id = university.id
        user.faculty_id = await sole_faculty_id(db_session, university)
    await db_session.commit()
    return body, user


def _bearer(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['tokens']['access_token']}"}


async def test_suggestions_is_the_only_path_to_this_handler(client, db_session):
    """One handler, one URL.

    The handler used to be registered at `/matching/suggestions` and at
    `/matching` as well. Two URLs means two things to keep working -- which one a
    client reaches depends on the base URL it was configured with -- and it makes
    the route table a worse description of the API than a list of alternatives
    would be. Asserted over the route table and over a request, because a route
    that is registered but unreachable fails only one of the two.
    """
    from app.main import create_app

    paths = create_app().openapi()["paths"]

    assert "/v1/matching" not in paths
    assert "post" in paths["/v1/matching/suggestions"]

    university, grades, units = await _campus(db_session)
    body, _me = await _account(
        client,
        db_session,
        "suggestions@mak.ac.ug",
        full_name="Suggestion Student",
        university=university,
    )
    await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="suggested@mak.ac.ug",
        full_name="Suggested Tutor",
    )
    await db_session.commit()

    payload = {"course_unit_id": str(units["CSC 121"].public_id)}
    canonical = await client.post(
        "/v1/matching/suggestions", json=payload, headers=_bearer(body)
    )
    alias = await client.post("/v1/matching", json=payload, headers=_bearer(body))

    assert canonical.status_code == 200, canonical.text
    assert alias.status_code == 404


async def test_a_unit_only_query_answers_without_a_request_id(client, db_session):
    """`request_id` is null when nothing backs it.

    The field names a help request the client could go and open, and an id minted
    by a unit-only query would name no row: the client would store it, follow it
    on the next screen, and get a 404 for a request it never made.
    """
    university, grades, units = await _campus(db_session)
    body, _me = await _account(
        client,
        db_session,
        "unit-only@mak.ac.ug",
        full_name="Unit Only",
        university=university,
    )
    tutor = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="unit-only-tutor@mak.ac.ug",
        full_name="Unit Only Tutor",
    )
    await db_session.commit()

    response = await client.post(
        "/v1/matching/suggestions",
        json={"course_unit_id": str(units["CSC 121"].public_id)},
        headers=_bearer(body),
    )

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["request_id"] is None
    assert [item["tutor"]["user_id"] for item in payload["candidates"]] == [
        str(tutor.public_id)
    ]


async def test_a_help_request_is_matched_against_its_own_course_unit(
    client, db_session
):
    """The request in the path decides the unit, and its id comes back.

    This route used to load the request and then match whatever the *body*
    carried, so a client asking "who can take this request" was answered about
    another course. Built so the body is wrong in a way that would have produced
    a plausible answer: a tutor who cannot help with the request's unit but is
    the only one for the unit the body named. Before the fix, the response said
    that tutor.
    """
    university, grades, units = await _campus(db_session, codes=("CSC 121", "CSC 122"))
    body, _me = await _account(
        client,
        db_session,
        "request-owner@mak.ac.ug",
        full_name="Request Owner",
        university=university,
    )
    wrong_unit_tutor = await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="wrong-unit@mak.ac.ug",
        full_name="Wrong Unit Tutor",
    )
    await db_session.commit()

    created = await client.post(
        "/v1/matching/help-requests",
        json={
            "course_unit_id": str(units["CSC 121"].public_id),
            "topic": "quick sort",
            "description": "Partitions.",
        },
        headers=_bearer(body),
    )
    assert created.status_code == 201, created.text
    request_id = created.json()["id"]

    right = await client.post(
        f"/v1/matching/help-requests/{request_id}/matches",
        json={"course_unit_id": str(units["CSC 121"].public_id)},
        headers=_bearer(body),
    )
    wrong = await client.post(
        f"/v1/matching/help-requests/{request_id}/matches",
        json={"course_unit_id": str(units["CSC 122"].public_id)},
        headers=_bearer(body),
    )

    assert right.status_code == 200, right.text
    payload = right.json()
    assert payload["request_id"] == request_id
    # CSC 121 has no eligible tutor, and CSC 122's tutor is not widened in
    # silently: the request's own unit is the whole question.
    assert payload["candidates"] == []
    assert payload["no_eligible_tutors"] is True
    assert str(wrong_unit_tutor.public_id) not in [
        item["tutor"]["user_id"] for item in payload["candidates"]
    ]
    # A body naming a different unit is refused, naming the field to fix.
    assert wrong.status_code == 422
    assert "course_unit_id" in wrong.json()["errors"]


async def test_a_request_belonging_to_someone_else_is_a_404(client, db_session):
    """Ownership is checked before anything is answered.

    A student who guesses another student's request id must not learn whether it
    exists, and must not get a ranked list of tutors for a topic that is not
    theirs.
    """
    university, grades, units = await _campus(db_session)
    owner_body, _owner = await _account(
        client,
        db_session,
        "owner@mak.ac.ug",
        full_name="Owner",
        university=university,
    )
    other_body, _other = await _account(
        client,
        db_session,
        "stranger@mak.ac.ug",
        full_name="Stranger",
        university=university,
    )
    await _competent_tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="shared@mak.ac.ug",
        full_name="Shared Tutor",
    )
    await db_session.commit()

    created = await client.post(
        "/v1/matching/help-requests",
        json={"course_unit_id": str(units["CSC 121"].public_id), "topic": "graphs"},
        headers=_bearer(owner_body),
    )
    request_id = created.json()["id"]

    read = await client.get(
        f"/v1/matching/help-requests/{request_id}", headers=_bearer(other_body)
    )
    matched = await client.post(
        f"/v1/matching/help-requests/{request_id}/matches",
        json={"course_unit_id": str(units["CSC 121"].public_id)},
        headers=_bearer(other_body),
    )

    assert read.status_code == 404
    assert read.json()["code"] == "not_found"
    assert matched.status_code == 404
    assert matched.json()["code"] == "not_found"
