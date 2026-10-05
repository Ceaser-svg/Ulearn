"""The tutor discovery rail, and one tutor's public profile.

Two different things are tested here and neither substitutes for the other.

The rules -- who may appear in a student-facing list at all -- are domain rules
about who holds a standing and a verified grade, and they are worth asserting
directly.

The wire contract is worth as much, and most of this file therefore goes through
the real router with real access tokens. A service that filters correctly, behind
a route wired without an auth guard or pointed at the wrong schema, passes every
service-level test and ships a directory of the whole university.

The last group is the regression that bit us: no `GET` may create a
`TutorProfile`. `TutorProfile` rows belong to users holding the tutor role and
are created when the role is granted, so a browse that minted one would hand
every signed-in student a `probationary` standing merely by opening the
discovery screen.
"""

from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import func, select

from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Subject, University
from app.models.endorsement import UnitEndorsement
from app.models.enums import (
    CompetencyStatus,
    SessionStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade, GradingScale
from app.models.session import Session
from app.models.tutor_profile import TutorProfile
from app.models.user import User, set_roles
from app.schemas.tutor import MAX_RAIL_TUTORS, RAIL_ENDORSED_UNITS
from tests.support import sole_faculty_id

GOOD_PASSWORD = "correct horse battery staple"


# --- wire helpers ----------------------------------------------------------
#
# Repeated from `test_endorsements.py` rather than imported, so a failure in
# either file points at the file that owns the case.


async def _register(client, email: str) -> dict:
    response = await client.post(
        "/v1/auth/register", json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _bearer(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['tokens']['access_token']}"}


async def _account(
    client,
    db_session,
    email: str,
    *,
    full_name: str | None = None,
    university: University | None = None,
) -> tuple[dict, User]:
    """Register a real account and give it a name and a university.

    Registering through the router is the only way to get a row carrying a
    usable password hash and a live access token. The name and the university are
    set directly rather than through `PATCH /v1/users/me`, because that endpoint
    is covered in its own tests and three requests per fixture would test the
    wizard rather than the rail.
    """
    body = await _register(client, email)
    user = await db_session.scalar(select(User).where(User.email == email))
    assert user is not None
    if full_name is not None:
        user.full_name = full_name
    if university is not None:
        user.university_id = university.id
        user.faculty_id = await sole_faculty_id(db_session, university)
    await db_session.commit()
    return body, user


# --- fixtures --------------------------------------------------------------


async def _institution(
    db_session,
    *,
    name: str = "Makerere University",
    codes: tuple[str, ...] = ("CSC 121",),
) -> tuple[University, Subject, dict[str, Grade], dict[str, CourseUnit]]:
    """A university whose scale gates competency at B+, with some course units.

    The bar is at 4.00 with `B+` at exactly 4.00 and `B` at 3.50, so "at or above
    the bar" has an unambiguous in and an unambiguous out and a test can state the
    boundary rather than the neighbourhood around it.
    """
    scale = GradingScale(
        name=f"{name} 5-point",
        max_points=Decimal("5.00"),
        competency_min_points=Decimal("4.00"),
    )
    university = University(name=name, grading_scale=scale)
    subject = Subject(name=f"{name} Faculty of Science")
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
    return university, subject, grades, units


async def _tutor(
    db_session,
    *,
    university: University,
    units: list[CourseUnit],
    grade: Grade,
    email: str,
    full_name: str | None,
    standing: TutorStanding = TutorStanding.VERIFIED,
    status: CompetencyStatus = CompetencyStatus.VERIFIED,
    completed_sessions: int = 5,
    rating_total: Decimal = Decimal("42.00"),
    rating_count: int = 10,
    profile: bool = True,
) -> User:
    """A tutor: a role, a profile unless asked otherwise, and one competency per unit.

    `profile=False` builds the one state that is a tutor by role and by grade
    but has nothing standing to be ranked on -- data the platform can reach if a
    profile is ever deleted or a competency is verified by a path that does not
    create one. Both the rail and matching have to have an answer for it, and a
    rule that is only tested against its own happy path is not a rule.
    """
    # Placed in the faculty of the units they teach rather than looked up: the same
    # answer by construction, and it cannot drift from the units a test is about to
    # look for this tutor under. Asserted because a fixture handed units from two
    # faculties has no single correct faculty to pick.
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
                completed_sessions=completed_sessions,
                rating_total=rating_total,
                rating_count=rating_count,
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


async def _endorse(
    db_session,
    *,
    tutor: User,
    rater: User,
    unit: CourseUnit,
    times: int,
) -> None:
    """Record `times` endorsements of `tutor` for `unit`, one per session.

    One row per session because that is the shape the claim takes: an endorsement
    is something a rater said about a session that happened, and the unique key
    on `(session_id, rater_id, course_unit_id)` is what makes a retried
    submission replace rather than double.
    """
    for index in range(times):
        session = Session(
            tutee_id=rater.id,
            tutor_id=tutor.id,
            course_unit_id=unit.id,
            topic=f"{unit.code} session {index}",
            status=SessionStatus.COMPLETED,
            started_at=datetime.now(UTC),
            ended_at=datetime.now(UTC),
            duration_minutes=60,
        )
        db_session.add(session)
        await db_session.flush()
        db_session.add(
            UnitEndorsement(
                session_id=session.id,
                rater_id=rater.id,
                ratee_id=tutor.id,
                course_unit_id=unit.id,
            )
        )
    await db_session.flush()


async def _profile_count(db_session) -> int:
    return await db_session.scalar(select(func.count()).select_from(TutorProfile))


async def _rail_ids(response) -> list[str]:
    assert response.status_code == 200, response.text
    return [entry["user_id"] for entry in response.json()]


# --- authentication --------------------------------------------------------


async def test_the_rail_needs_a_token(client) -> None:
    """Unauthenticated is a 401, before anything is looked up.

    A discovery rail is the endpoint that would list every tutor at an
    institution, so it is the one that most needs the guard; asserting it here
    rather than trusting the dependency means a route rewritten without
    `CurrentUser` fails a test instead of shipping.
    """
    response = await client.get("/v1/tutors/top")

    assert response.status_code == 401
    assert response.json()["code"] == "authentication_required"


async def test_the_detail_screen_needs_a_token(client) -> None:
    response = await client.get("/v1/tutors/8f3a2c1e-0000-4000-8000-000000000000")

    assert response.status_code == 401


async def test_a_student_without_a_university_is_refused(client, db_session) -> None:
    """The rail is defined as their own university's tutors, so there is nothing
    to fall back to.

    A 422 with the field named, because the remedy is one onboarding step away
    and the app can send the student to it. An empty rail would look like a
    university with no tutors in it.
    """
    body, _student = await _account(client, db_session, "no-uni@mak.ac.ug")

    response = await client.get("/v1/tutors/top", headers=_bearer(body))

    assert response.status_code == 422
    assert response.json()["code"] == "validation_failed"
    assert "university_id" in response.json()["errors"]


# --- the rail's contents ----------------------------------------------------


async def test_the_rail_lists_eligible_tutors_with_their_evidence(
    client, db_session
) -> None:
    """What a rail row has to carry for the screen to render without a second call."""
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "browse-me@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="rail-tutor@mak.ac.ug",
        full_name="Rail Tutor",
        completed_sessions=9,
        rating_total=Decimal("41.00"),
        rating_count=10,
    )
    _me_row, rater = await _account(
        client, db_session, "browse-rater@mak.ac.ug", university=university
    )
    await _endorse(db_session, tutor=tutor, rater=rater, unit=units["CSC 121"], times=3)
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert response.status_code == 200, response.text
    assert response.json() == [
        {
            "user_id": str(tutor.public_id),
            "full_name": "Rail Tutor",
            "standing": "verified",
            # A JSON string, deliberately: the same `Decimal` the promotion rule
            # compared, which a double could not carry.
            "average_rating": "4.10",
            "completed_sessions": 9,
            "endorsed_course_unit_ids": [str(units["CSC 121"].public_id)],
            "endorsement_count": 3,
        }
    ]


async def test_a_suspended_tutor_is_absent_from_the_rail(client, db_session) -> None:
    """Invariant 5: a suspended tutor appears in no student-facing list.

    Asserted on both paths, because the filter is one clause and a second path
    that forgot it would be a regression rather than a bug nobody could have
    predicted.
    """
    university, _subject, grades, units = await _institution(
        db_session, codes=("CSC 121", "CSC 122")
    )
    caller, _me = await _account(
        client, db_session, "suspend-me@mak.ac.ug", university=university
    )
    good = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="kept-tutor@mak.ac.ug",
        full_name="Kept Tutor",
    )
    suspended = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="gone-tutor@mak.ac.ug",
        full_name="Gone Tutor",
        standing=TutorStanding.SUSPENDED,
    )
    await db_session.commit()

    unfiltered = await client.get("/v1/tutors/top", headers=_bearer(caller))
    filtered = await client.get(
        "/v1/tutors/top",
        params={"course_unit_id": str(units["CSC 121"].public_id)},
        headers=_bearer(caller),
    )

    assert await _rail_ids(unfiltered) == [str(good.public_id)]
    assert await _rail_ids(filtered) == [str(good.public_id)]
    assert str(suspended.public_id) not in await _rail_ids(unfiltered)


async def test_a_tutor_at_another_university_is_absent(client, db_session) -> None:
    """The university boundary is discovery's first rule."""
    home, _subject, home_grades, home_units = await _institution(db_session)
    elsewhere, _other_subject, other_grades, other_units = await _institution(
        db_session,
        name="Ndejje University",
        codes=("CSC 121",),
    )
    caller, _me = await _account(
        client, db_session, "home-me@mak.ac.ug", university=home
    )
    local = await _tutor(
        db_session,
        university=home,
        units=[home_units["CSC 121"]],
        grade=home_grades["A"],
        email="local-tutor@mak.ac.ug",
        full_name="Local Tutor",
    )
    _foreign = await _tutor(
        db_session,
        university=elsewhere,
        units=[other_units["CSC 121"]],
        grade=other_grades["A"],
        email="foreign-tutor@nde.ac.ug",
        full_name="Foreign Tutor",
    )
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert await _rail_ids(response) == [str(local.public_id)]


async def test_the_caller_is_absent_from_their_own_rail(client, db_session) -> None:
    """A student who is also a tutor does not rank themselves.

    They are the one person on the rail who already knows what they look like,
    and their row would occupy a slot a student's shortlist could have used.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "both-roles@mak.ac.ug", university=university
    )
    other = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="other-tutor@mak.ac.ug",
        full_name="Other Tutor",
    )
    # The caller earns the tutor role the only way the platform allows: a
    # verified competency, which is also what creates their profile.
    db_session.add(
        Competency(
            user=_me,
            course_unit=units["CSC 121"],
            grade=grades["A"],
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    db_session.add(TutorProfile(user=_me, standing=TutorStanding.VERIFIED))
    await db_session.flush()
    await set_roles(db_session, _me.id, {UserRole.STUDENT, UserRole.TUTOR})
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert await _rail_ids(response) == [str(other.public_id)]


async def test_a_user_with_no_profile_is_absent_and_is_not_given_one(
    client, db_session
) -> None:
    """A verified grade and the tutor role, with no standing to rank on.

    The exclusion is on the profile's absence -- there is no standing to show and
    no counters to report -- and reading the rail must not fix that by minting
    the row. Both halves are asserted, because the second is the regression this
    file exists to prevent.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "profileless-me@mak.ac.ug", university=university
    )
    profileless = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="profileless@mak.ac.ug",
        full_name="Profileless Tutor",
        profile=False,
    )
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert await _rail_ids(response) == []
    profile = await db_session.scalar(
        select(TutorProfile).where(TutorProfile.user_id == profileless.id)
    )
    assert profile is None, "browsing created a tutor profile"


async def test_an_unrated_tutor_reports_no_average(client, db_session) -> None:
    """`null`, not zero: no ratings is not a bad rating.

    The rail shows the mean straight off the stored total and count, so a tutor
    with `rating_count = 0` has nothing to divide and the field is null.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "unrated-me@mak.ac.ug", university=university
    )
    await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="unrated-tutor@mak.ac.ug",
        full_name="Unrated Tutor",
        rating_total=Decimal("0"),
        rating_count=0,
    )
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert response.json()[0]["average_rating"] is None


async def test_a_repeating_mean_is_rounded_for_the_wire(client, db_session) -> None:
    """Eight ratings totalling 33 is 4.125, and the wire says 4.13.

    Every rating schema declares two decimal places, and Pydantic v2 validates
    rather than rounds: the exact mean raised a validation error and the rail
    answered 500. That is not a display preference failing, it is a tutor whose
    ratings happened not to divide evenly losing their own standing -- and it
    was the same bug on the detail screen, on matching, and on
    `GET /v1/ratings/me`, all of which carry the same field.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "third-rated@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="third-rated-tutor@mak.ac.ug",
        full_name="Third Rated Tutor",
        rating_total=Decimal("33.00"),
        rating_count=8,
    )
    await db_session.commit()

    entry = (await client.get("/v1/tutors/top", headers=_bearer(caller))).json()[0]

    assert entry["user_id"] == str(tutor.public_id)
    assert entry["average_rating"] == "4.13"


async def test_a_nameless_tutor_is_listed_under_their_email(client, db_session) -> None:
    """An account with no name is a real state, not an error.

    `users.full_name` is nullable because the onboarding wizard can be abandoned,
    so a tutor in the middle of signing up holds the role and shows up in a
    student's rail. The email is the only other thing there is to display.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "nameless-me@mak.ac.ug", university=university
    )
    await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="nameless-tutor@mak.ac.ug",
        full_name=None,
    )
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert response.json()[0]["full_name"] == "nameless-tutor@mak.ac.ug"


# --- the unit filter --------------------------------------------------------


async def test_the_unit_filter_keeps_only_tutors_of_that_unit(
    client, db_session
) -> None:
    """The filter is a gate, not a sort: a tutor who cannot help here is absent."""
    university, _subject, grades, units = await _institution(
        db_session, codes=("CSC 121", "CSC 122")
    )
    caller, _me = await _account(
        client, db_session, "filter-me@mak.ac.ug", university=university
    )
    algorithms = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="algorithms@mak.ac.ug",
        full_name="Algorithms Tutor",
    )
    _compiler = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="compiler@mak.ac.ug",
        full_name="Compiler Tutor",
    )
    await db_session.commit()

    filtered = await client.get(
        "/v1/tutors/top",
        params={"course_unit_id": str(units["CSC 121"].public_id)},
        headers=_bearer(caller),
    )

    assert await _rail_ids(filtered) == [str(algorithms.public_id)]


async def test_without_a_unit_filter_the_rail_spans_the_university(
    client, db_session
) -> None:
    """The no-picker path, which is what makes the rail useful on first paint.

    Every verified competency at the caller's own university is considered, so a
    tutor from any unit can appear.
    """
    university, _subject, grades, units = await _institution(
        db_session, codes=("CSC 121", "CSC 122")
    )
    caller, _me = await _account(
        client, db_session, "wide-me@mak.ac.ug", university=university
    )
    algorithms = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="wide-a@mak.ac.ug",
        full_name="Algorithms Tutor",
    )
    compiler = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="wide-b@mak.ac.ug",
        full_name="Compiler Tutor",
    )
    await db_session.commit()

    response = await client.get("/v1/tutors/top", headers=_bearer(caller))

    assert sorted(await _rail_ids(response)) == sorted(
        [str(algorithms.public_id), str(compiler.public_id)]
    )


async def test_the_unit_filter_still_applies_the_competency_bar(
    client, db_session
) -> None:
    """A verified grade below B+ does not put a tutor on a rail for that unit.

    The bar is `competency_min_points` on the university's scale, so a `B` at
    3.50 is out and the `B+` at exactly 4.00 is in. The boundary matters: a gate
    compared with `>` instead of `>=` would refuse the single most common grade a
    tutor holds.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "bar-me@mak.ac.ug", university=university
    )
    at_the_bar = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B+"],
        email="at-the-bar@mak.ac.ug",
        full_name="At The Bar Tutor",
    )
    below = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B"],
        email="below-bar@mak.ac.ug",
        full_name="Below Bar Tutor",
    )
    pending = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        status=CompetencyStatus.PENDING,
        email="pending@mak.ac.ug",
        full_name="Pending Tutor",
    )
    await db_session.commit()

    response = await client.get(
        "/v1/tutors/top",
        params={"course_unit_id": str(units["CSC 121"].public_id)},
        headers=_bearer(caller),
    )

    assert await _rail_ids(response) == [str(at_the_bar.public_id)]
    assert str(below.public_id) not in await _rail_ids(response)
    assert str(pending.public_id) not in await _rail_ids(response)


async def test_an_unknown_or_foreign_unit_filter_gives_an_empty_rail(
    client, db_session
) -> None:
    """A stale picker value is "no tutors", not an error state.

    Same rule as `GET /v1/academics/course-units`: the client filtered on a value
    it believed existed, and the honest answer to "tutors for this unit" is none.
    A 422 here would put a student's discovery screen into an error state over a
    unit that was deleted, which is something they did not do.
    """
    university, _subject, _grades, units = await _institution(db_session)
    _elsewhere, _other_subject, _other_grades, other_units = await _institution(
        db_session,
        name="Ndejje University",
        codes=("CSC 121",),
    )
    caller, _me = await _account(
        client, db_session, "stale-me@mak.ac.ug", university=university
    )
    await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=_grades["A"],
        email="stale-tutor@mak.ac.ug",
        full_name="Stale Tutor",
    )
    await db_session.commit()

    unknown = await client.get(
        "/v1/tutors/top",
        params={"course_unit_id": "00000000-0000-4000-8000-000000000000"},
        headers=_bearer(caller),
    )
    foreign = await client.get(
        "/v1/tutors/top",
        params={"course_unit_id": str(other_units["CSC 121"].public_id)},
        headers=_bearer(caller),
    )

    assert unknown.status_code == 200
    assert await _rail_ids(unknown) == []
    assert foreign.status_code == 200
    assert await _rail_ids(foreign) == []


# --- ranking ----------------------------------------------------------------


async def test_the_rail_is_ranked_and_deterministic(client, db_session) -> None:
    """The whole ordering, asserted position by position.

    Built so that each key is load-bearing and the ones below it cannot rescue a
    row:

    - Alpha and Bravo have the most endorsements, so they lead whatever their
      rating says. Charlie has the highest average of anyone and is still below
      them, because one endorsement is one endorsement.
    - Golf, Echo and Foxtrot tie on endorsements and average; Golf wins on
      sessions, then Echo and Foxtrot tie on everything and are separated by
      name.
    - Delta is unrated and last of the endorsers despite the most sessions of
      anyone, which is "nulls last" rather than "nulls are a score".
    - Hotel has no endorsements at all -- the outer join's null, which must rank
      as zero -- and comes last.

    Asked for twice, because an ordering without a final tiebreak produces a
    different answer whenever the query plan does. A rail that reorders itself
    between two paints of the same screen reads as the platform changing its
    mind.
    """
    university, _subject, grades, units = await _institution(
        db_session, codes=("CSC 121",)
    )
    caller, _me = await _account(
        client, db_session, "rank-me@mak.ac.ug", university=university
    )
    _rater_body, rater = await _account(
        client, db_session, "rank-rater@mak.ac.ug", university=university
    )

    # (name, endorsements, rating total, rating count, completed sessions)
    #
    # A stored total, not a mean: `rating_total` is what the model divides, and
    # a fixture that passed 4.5 as the total of ten ratings would be refused by
    # the `rating_total >= rating_count` constraint rather than ranking anyone.
    specs = [
        ("Alpha Tutor", 3, "45.00", 10, 10),
        ("Bravo Tutor", 3, "45.00", 10, 10),
        ("Charlie Tutor", 1, "100.00", 20, 20),
        ("Delta Tutor", 2, "0", 0, 50),
        ("Echo Tutor", 2, "49.00", 10, 5),
        ("Foxtrot Tutor", 2, "49.00", 10, 5),
        ("Golf Tutor", 2, "49.00", 10, 30),
        ("Hotel Tutor", 0, "42.00", 10, 1),
    ]
    order: list[str] = []
    for name, endorsements, total, count, sessions in specs:
        slug = name.split()[0].lower()
        tutor = await _tutor(
            db_session,
            university=university,
            units=[units["CSC 121"]],
            grade=grades["A"],
            email=f"{slug}@mak.ac.ug",
            full_name=name,
            rating_total=Decimal(total),
            rating_count=count,
            completed_sessions=sessions,
        )
        order.append(str(tutor.public_id))
        if endorsements:
            await _endorse(
                db_session,
                tutor=tutor,
                rater=rater,
                unit=units["CSC 121"],
                times=endorsements,
            )
    await db_session.commit()

    first = await client.get("/v1/tutors/top", headers=_bearer(caller))
    second = await client.get("/v1/tutors/top", headers=_bearer(caller))

    expected = [
        order[0],  # Alpha
        order[1],  # Bravo
        order[6],  # Golf, most sessions among the three tied on rating
        order[4],  # Echo, then Foxtrot on name
        order[5],  # Foxtrot
        order[3],  # Delta, unrated, last of the endorsers
        order[2],  # Charlie, one endorsement
        order[7],  # Hotel, none
    ]
    assert await _rail_ids(first) == expected
    assert await _rail_ids(second) == expected


async def test_the_rail_honours_its_limit(client, db_session) -> None:
    """A shorter limit is the top of the same order, not a different order."""
    university, _subject, grades, units = await _institution(
        db_session, codes=("CSC 121", "CSC 122")
    )
    caller, _me = await _account(
        client, db_session, "limit-me@mak.ac.ug", university=university
    )
    first = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="limit-a@mak.ac.ug",
        full_name="Limit A",
    )
    second = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="limit-b@mak.ac.ug",
        full_name="Limit B",
    )
    await db_session.commit()

    everything = await _rail_ids(
        await client.get("/v1/tutors/top", headers=_bearer(caller))
    )
    shortened = await _rail_ids(
        await client.get("/v1/tutors/top", params={"limit": 1}, headers=_bearer(caller))
    )

    # Two tutors on identical evidence, so the name decides and the assertion is
    # about the slice rather than about which of them happens to rank higher.
    assert sorted(everything) == sorted([str(first.public_id), str(second.public_id)])
    assert shortened == everything[:1]


async def test_an_out_of_range_limit_is_refused_at_the_edge(client, db_session) -> None:
    """Refused before any query runs.

    The bound is on what a client may *ask for*, not on how many tutors exist, so
    it belongs on the parameter: an unbounded rail is a full table scan of a
    university's tutors on a metered connection.
    """
    university, _subject, _grades, _units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "bound-me@mak.ac.ug", university=university
    )

    too_many = await client.get(
        "/v1/tutors/top",
        params={"limit": MAX_RAIL_TUTORS + 1},
        headers=_bearer(caller),
    )
    too_few = await client.get(
        "/v1/tutors/top", params={"limit": 0}, headers=_bearer(caller)
    )

    assert too_many.status_code == 422
    assert too_few.status_code == 422


async def test_the_endorsed_unit_list_is_capped_but_the_total_is_not(
    client, db_session
) -> None:
    """Five units are shown; the count is the truth.

    A tutor endorsed in six units is not summarised by any five of them, so the
    entry carries the real total next to a sample. The cap is what keeps a rail
    row a rail row.
    """
    codes = tuple(f"CSC {number}" for number in (110, 120, 130, 140, 150, 160))
    university, _subject, grades, units = await _institution(db_session, codes=codes)
    caller, _me = await _account(
        client, db_session, "capped-me@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 110"]],
        grade=grades["A"],
        email="widely-taught@mak.ac.ug",
        full_name="Widely Taught",
    )
    _rater_body, rater = await _account(
        client, db_session, "capped-rater@mak.ac.ug", university=university
    )
    for code in codes:
        await _endorse(db_session, tutor=tutor, rater=rater, unit=units[code], times=1)
    await db_session.commit()

    entry = (await client.get("/v1/tutors/top", headers=_bearer(caller))).json()[0]

    assert entry["endorsement_count"] == len(codes)
    assert len(entry["endorsed_course_unit_ids"]) == RAIL_ENDORSED_UNITS
    # Ordered by count then course code, so the sample is stable.
    assert entry["endorsed_course_unit_ids"] == [
        str(units[code].public_id) for code in sorted(codes)[:RAIL_ENDORSED_UNITS]
    ]


async def test_a_tutor_with_no_endorsements_reports_zero_and_no_units(
    client, db_session
) -> None:
    """Zero endorsements is an empty list and a zero count, not a null and not
    an error.

    A null would read as "unknown", and the row would look like the aggregate
    failed rather than like a tutor who has not been reviewed yet.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "fresh-me@mak.ac.ug", university=university
    )
    await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="fresh-tutor@mak.ac.ug",
        full_name="Fresh Tutor",
    )
    await db_session.commit()

    entry = (await client.get("/v1/tutors/top", headers=_bearer(caller))).json()[0]

    assert entry["endorsement_count"] == 0
    assert entry["endorsed_course_unit_ids"] == []


# --- the detail screen ------------------------------------------------------


async def test_the_detail_screen_returns_the_trimmed_profile(
    client, db_session
) -> None:
    """The body is `TutorProfileSummary`, so the suspension reason and the raw
    rating total cannot reach a student.

    Asserted on the keys rather than on values, because a field that is present
    and null is still a field the student can be shown: it tells them the
    platform has a judgement about this tutor and is choosing not to say it.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "detail-me@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="detail-tutor@mak.ac.ug",
        full_name="Detail Tutor",
        completed_sessions=7,
        rating_total=Decimal("33.00"),
        rating_count=8,
    )
    profile = await db_session.scalar(
        select(TutorProfile).where(TutorProfile.user_id == tutor.id)
    )
    profile.suspended_reason = "Repeated no-shows"
    _rater_body, rater = await _account(
        client, db_session, "detail-rater@mak.ac.ug", university=university
    )
    await _endorse(db_session, tutor=tutor, rater=rater, unit=units["CSC 121"], times=2)
    await db_session.commit()

    response = await client.get(
        f"/v1/tutors/{tutor.public_id}", headers=_bearer(caller)
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["profile"] == {
        "user_id": str(tutor.public_id),
        "full_name": "Detail Tutor",
        "standing": "verified",
        "average_rating": "4.13",
        "completed_sessions": 7,
    }
    assert "suspended_reason" not in body["profile"]
    assert "rating_total" not in body["profile"]
    assert body["endorsed_course_unit_ids"] == [str(units["CSC 121"].public_id)]
    assert body["endorsement_count"] == 2


async def test_the_detail_screen_caps_its_unit_list_too(client, db_session) -> None:
    """Same sample, same cap, same reason as the rail.

    A client rendering a rail row and a detail row from two different
    assumptions about the list length is a client that lays out thirty chips on a
    page built for five, so the detail screen is bounded by the same constant and
    the count beside it is the total.
    """
    codes = tuple(f"CSC {number}" for number in (110, 120, 130, 140, 150, 160))
    university, _subject, grades, units = await _institution(db_session, codes=codes)
    caller, _me = await _account(
        client, db_session, "wide-detail@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 110"]],
        grade=grades["A"],
        email="wide-detail-tutor@mak.ac.ug",
        full_name="Wide Detail Tutor",
    )
    _rater_body, rater = await _account(
        client, db_session, "wide-detail-rater@mak.ac.ug", university=university
    )
    for code in codes:
        await _endorse(db_session, tutor=tutor, rater=rater, unit=units[code], times=1)
    await db_session.commit()

    response = await client.get(
        f"/v1/tutors/{tutor.public_id}", headers=_bearer(caller)
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["endorsed_course_unit_ids"]) == RAIL_ENDORSED_UNITS
    assert body["endorsement_count"] == len(codes)


async def test_a_suspended_tutor_is_still_readable_on_the_detail_screen(
    client, db_session
) -> None:
    """The rail hides them; the detail screen shows the standing.

    A student who booked a suspended tutor has to be able to find out, and
    hiding the profile would leave them with a screen that stopped working rather
    than a screen that says what happened.
    """
    university, _subject, grades, units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "suspended-detail@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="suspended-tutor@mak.ac.ug",
        full_name="Suspended Tutor",
        standing=TutorStanding.SUSPENDED,
    )
    await db_session.commit()

    response = await client.get(
        f"/v1/tutors/{tutor.public_id}", headers=_bearer(caller)
    )

    assert response.status_code == 200, response.text
    assert response.json()["profile"]["standing"] == "suspended"


async def test_an_unknown_user_is_a_404(client, db_session) -> None:
    university, _subject, _grades, _units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "absent-me@mak.ac.ug", university=university
    )

    response = await client.get(
        "/v1/tutors/00000000-0000-4000-8000-000000000000",
        headers=_bearer(caller),
    )

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


async def test_a_user_who_is_not_a_tutor_is_a_404(client, db_session) -> None:
    """Same answer as "no such user", deliberately.

    Distinguishing them would make the route a way to learn which accounts hold
    the tutor role, which is the one thing a browse surface must not become.
    """
    university, _subject, _grades, _units = await _institution(db_session)
    caller, _me = await _account(
        client, db_session, "peer-me@mak.ac.ug", university=university
    )
    _other_body, classmate = await _account(
        client, db_session, "classmate@mak.ac.ug", university=university
    )

    response = await client.get(
        f"/v1/tutors/{classmate.public_id}", headers=_bearer(caller)
    )

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


async def test_a_malformed_tutor_id_is_a_422(client, db_session) -> None:
    """A bad path segment is a framework validation error, rendered as one.

    The problem document is asserted on because it is the shape the client
    parses; FastAPI's default 422 is a list of objects keyed by `loc`, which is a
    second shape the app would have to special-case.
    """
    caller, _me = await _account(client, db_session, "malformed@mak.ac.ug")

    response = await client.get("/v1/tutors/not-a-uuid", headers=_bearer(caller))

    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")


# --- reads never write ------------------------------------------------------


async def test_no_read_on_this_surface_creates_a_tutor_profile(
    client, db_session
) -> None:
    """Every `GET` this module offers, then the row count, unchanged.

    This is the regression: `get_tutor_rating_summary` once called
    `_get_or_create_tutor_profile`, so opening the screen handed every signed-in
    student a `probationary` standing and a row. A rail is opened far more often
    than a profile is, so the same mistake here would hand one out on every cold
    start.

    Every route is hit, including the ones that 404 and the ones that return an
    empty list: a path that returned early would skip the write it was written
    around.
    """
    codes = ("CSC 121", "CSC 122")
    university, _subject, grades, units = await _institution(db_session, codes=codes)
    caller, me = await _account(
        client, db_session, "read-only-me@mak.ac.ug", university=university
    )
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="read-only-tutor@mak.ac.ug",
        full_name="Read Only Tutor",
    )
    _profileless = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="read-only-profileless@mak.ac.ug",
        full_name="Read Only Profileless",
        profile=False,
    )
    _nameless_body, nameless = await _account(
        client, db_session, "read-only-nameless@mak.ac.ug", university=university
    )
    await db_session.commit()

    before = await _profile_count(db_session)
    assert before == 1, "the fixture is wrong, not the service"

    headers = _bearer(caller)
    requests = [
        ("get", "/v1/tutors/top", None),
        ("get", "/v1/tutors/top", {"limit": 1}),
        (
            "get",
            "/v1/tutors/top",
            {"course_unit_id": str(units["CSC 121"].public_id)},
        ),
        (
            "get",
            "/v1/tutors/top",
            {"course_unit_id": "00000000-0000-4000-8000-000000000000"},
        ),
        ("get", f"/v1/tutors/{tutor.public_id}", None),
        ("get", f"/v1/tutors/{me.public_id}", None),
        ("get", f"/v1/tutors/{nameless.public_id}", None),
        ("get", "/v1/tutors/00000000-0000-4000-8000-000000000000", None),
        ("get", "/v1/ratings/me", None),
    ]
    for method, path, params in requests:
        response = await client.request(method, path, params=params, headers=headers)
        assert response.status_code < 500, f"{path} -> {response.status_code}"

    assert await _profile_count(db_session) == before
    for user in (me, nameless, _profileless):
        profile = await db_session.scalar(
            select(TutorProfile).where(TutorProfile.user_id == user.id)
        )
        assert profile is None, f"reading created a tutor profile for {user.email}"


# --- imports used only for the assertions above ---------------------------


def test_the_rail_module_imports_no_private_service_helpers() -> None:
    """`app.services` is a package of public functions.

    Reaching into another module's `_`-prefixed name works until the thing it
    points at is renamed, and the matching router was reaching into two of them
    when this was written. Asserted rather than left to review because the failure
    is silent -- the attribute simply stops existing, at import time, in a module
    nothing else touches.
    """
    import inspect

    from app.api.v1 import tutors
    from app.services import rating_service, tutor_service

    source = inspect.getsource(tutors)
    assert "rating_service._" not in source
    assert "tutor_service._" not in source
    assert "matching_service._" not in source

    for module in (rating_service, tutor_service):
        assert module.__doc__
