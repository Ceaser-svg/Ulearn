"""The faculty silo, asserted at every surface that can act on a course unit.

The rest of the suite had to be given a faculty on every staged account, which is
itself a measure of how wide this rule reaches: an account with no faculty can
list no course, ask for no help, prove no competence, and see no tutor. Those are
preconditions, not the rule. This module is the rule, one test per surface, and
each test names the surface it is about instead of asserting that a 422 happened
somewhere.

The fixture reads the seeded pilot rather than building a parallel world, so these
tests describe the catalogue the product actually ships -- including the fact that
four of its six faculties hold no course units at all, which is the empty state a
real student hits first.

Two faculties of one university is the whole setup. A second *university* would not
test the silo, it would re-test the boundary that already existed: the interesting
case is two faculties the existing check treated as interchangeable.
"""

from decimal import Decimal

import pytest
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Subject
from app.models.enums import (
    CompetencyStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade
from app.models.tutor_profile import TutorProfile
from app.models.user import User, set_roles
from tests.conftest import CommittedEnv
from tests.support import bearer, register

UNITS_URL = "/v1/academics/course-units"

OWN_FACULTY = "Faculty of Computing and Informatics Sciences"
OTHER_FACULTY = "Faculty of Science"
EMPTY_FACULTY = "Faculty of Medicine"
OWN_UNIT_CODE = "BIT 221"
OTHER_UNIT_CODE = "SCH 211"


@pytest.fixture
async def pilot(committed_env: CommittedEnv) -> dict:
    """The seeded catalogue, resolved to the rows these tests name.

    Read through the same session the requests use rather than staged, so the
    ids are the real ones and a change to the seed shows up here as a failure
    rather than as a fixture quietly working around it.
    """
    async with committed_env.session() as session:
        units = {
            unit.code: unit
            for unit in (
                (
                    await session.execute(
                        select(CourseUnit).options(selectinload(CourseUnit.subject))
                    )
                )
                .scalars()
                .all()
            )
        }
        subjects = {
            subject.name: subject
            for subject in ((await session.execute(select(Subject))).scalars().all())
        }
        grade = (
            (await session.execute(select(Grade).where(Grade.label == "A").limit(1)))
            .scalars()
            .first()
        )
        university_id = units[OWN_UNIT_CODE].university_id

    assert grade is not None, "the seed must publish a passing grade"
    assert university_id is not None
    return {
        "own": subjects[OWN_FACULTY],
        "other": subjects[OTHER_FACULTY],
        "empty": subjects[EMPTY_FACULTY],
        "own_unit": units[OWN_UNIT_CODE],
        "other_unit": units[OTHER_UNIT_CODE],
        "grade": grade,
    }


async def _in_faculty(
    env: CommittedEnv,
    pilot: dict,
    faculty: Subject,
    email: str,
    *,
    roles: set[UserRole] | None = None,
    consent: bool = True,
) -> tuple[dict, User]:
    """A registered account placed in `faculty`, by the route a user takes.

    `PATCH /v1/users/me` rather than a direct column write: choosing a faculty is
    the wizard's second step, and a test about the silo should not be the one
    place that skips it.
    """
    client = env.client
    body = await register(client, email)
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]
    response = await client.patch(
        "/v1/users/me",
        headers=bearer(body),
        json={
            "university_id": university_id,
            "faculty_id": str(faculty.public_id),
            "academic_data_consented": consent,
        },
    )
    assert response.status_code == 200, response.text
    async with env.session() as session:
        user = await session.scalar(select(User).where(User.email == email))
        assert user is not None
        if roles:
            await set_roles(session, user.id, roles)
            await session.commit()
        return body, user


async def _tutor_in(
    env: CommittedEnv,
    pilot: dict,
    faculty: Subject,
    unit: CourseUnit,
    email: str,
) -> User:
    """A verified tutor in `faculty`, competent in `unit`, with a standing."""
    _body, _user = await _in_faculty(
        env, pilot, faculty, email, roles={UserRole.STUDENT, UserRole.TUTOR}
    )
    async with env.session() as session:
        tutor = await session.scalar(select(User).where(User.email == email))
        assert tutor is not None
        session.add(
            TutorProfile(
                user_id=tutor.id,
                standing=TutorStanding.VERIFIED,
                completed_sessions=4,
                rating_total=Decimal("19.00"),
                rating_count=4,
            )
        )
        session.add(
            Competency(
                user_id=tutor.id,
                course_unit_id=unit.id,
                grade_id=pilot["grade"].id,
                status=CompetencyStatus.VERIFIED,
                source=VerificationSource.TRANSCRIPT,
            )
        )
        await session.commit()
    return tutor


# --- the catalogue ---------------------------------------------------------


async def test_the_catalogue_offers_only_your_own_faculty(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The reported bug, at its source.

    A Computing student is offered all three Computing units and none of the
    Science ones. Not "the client filters them out" -- the endpoint never returns
    another faculty's units at all, so a client that forgot to filter would still
    be correct.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "bit.student@must.ac.ug"
    )

    units = (await committed_env.client.get(UNITS_URL, headers=bearer(body))).json()

    assert {unit["code"] for unit in units} == {"BIT 221", "BIT 223", "BIT 225"}


async def test_a_faculty_with_no_course_units_is_offered_none(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The other direction, and the one a student actually hits first.

    Medicine is one of four seeded faculties holding no units. The answer has to
    be an empty list the client can render as an empty state: a 404, or a refusal,
    would put a new student into an error screen over a fact about the catalogue
    rather than about them.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["empty"], "med.student@must.ac.ug"
    )

    units = (await committed_env.client.get(UNITS_URL, headers=bearer(body))).json()

    assert units == []


async def test_an_account_with_no_faculty_is_offered_no_courses(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """Mid-onboarding is a real state, not a bug, and it lists nothing.

    A student who has chosen a university but not yet a faculty has no courses to
    act on. Returning everything would leak the whole pilot catalogue to an
    account that has not been placed anywhere; refusing would break the wizard,
    which reads the catalogue on the way to choosing.
    """
    client = committed_env.client
    body = await register(client, "halfway@must.ac.ug")

    units = (await client.get(UNITS_URL, headers=bearer(body))).json()

    assert units == []


async def test_asking_for_another_faculty_by_filter_returns_nothing(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The query string can only narrow the answer, never widen it.

    `subject_id` is a rendering filter, not an authorisation input. A Computing
    student who names the Science faculty explicitly is owed an empty list,
    because that is what the picker asked for when no such course is theirs.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "filter.student@must.ac.ug"
    )

    units = (
        await committed_env.client.get(
            UNITS_URL,
            headers=bearer(body),
            params={"subject_id": str(pilot["other"].public_id)},
        )
    ).json()

    assert units == []


# --- acting on a course ----------------------------------------------------


async def test_a_help_request_cannot_be_raised_against_another_faculty(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The rule at the first write that names a course."""
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "bit.requester@must.ac.ug"
    )

    response = await committed_env.client.post(
        "/v1/matching/help-requests",
        headers=bearer(body),
        json={
            "course_unit_id": str(pilot["other_unit"].public_id),
            "topic": "titration",
        },
    )

    assert response.status_code == 422, response.text
    assert "faculty" in response.json()["detail"].lower()


async def test_matching_cannot_be_asked_about_another_faculty(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """And at the read that answers it.

    The same unit id a stale picker can still be holding, refused with the faculty
    named -- because "wrong faculty" and "no such unit" are different answers and
    the student can act on only one of them.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "bit.matcher@must.ac.ug"
    )

    response = await committed_env.client.post(
        "/v1/matching/suggestions",
        headers=bearer(body),
        json={"course_unit_id": str(pilot["other_unit"].public_id)},
    )

    assert response.status_code == 422, response.text


async def test_a_tutor_cannot_apply_to_verify_against_another_faculty(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """Verification is where the silo has to start.

    A Computing tutor proven against a Science unit would otherwise carry a
    verified competency into a faculty whose students are never shown them -- a
    record that says "verified" and means nothing to anybody.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "bit.applicant@must.ac.ug"
    )

    response = await committed_env.client.post(
        "/v1/competencies",
        headers=bearer(body),
        json={
            "course_unit_id": str(pilot["other_unit"].public_id),
            "grade_id": str(pilot["grade"].public_id),
            "source": "transcript",
        },
    )

    assert response.status_code == 422, response.text


async def test_a_primary_module_cannot_be_chosen_from_another_faculty(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """A profile cannot list a course its owner may not act on.

    Primary modules seed the matching phase, so accepting one from another faculty
    would put a course on the profile that every other endpoint then refuses,
    leaving the profile as the single place the silo did not hold.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "bit.primary@must.ac.ug"
    )

    response = await committed_env.client.patch(
        "/v1/users/me",
        headers=bearer(body),
        json={"primary_course_unit_ids": [str(pilot["other_unit"].public_id)]},
    )

    assert response.status_code == 422, response.text


async def test_a_faculty_and_its_own_modules_may_be_sent_together(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The wizard's ordering, which is the client's normal path.

    Onboarding sends the faculty and the first modules as separate steps, but a
    client that batches them is not doing anything wrong. Validated against the
    faculty chosen in this request rather than the one held before it, or the
    first module of every new account would be refused.
    """
    client = committed_env.client
    body = await register(client, "batched@must.ac.ug")
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]

    response = await client.patch(
        "/v1/users/me",
        headers=bearer(body),
        json={
            "university_id": university_id,
            "faculty_id": str(pilot["own"].public_id),
            "primary_course_unit_ids": [str(pilot["own_unit"].public_id)],
        },
    )

    assert response.status_code == 200, response.text
    profile = response.json()
    assert profile["faculty_id"] == str(pilot["own"].public_id)
    assert profile["primary_course_unit_ids"] == [str(pilot["own_unit"].public_id)]


async def test_changing_faculty_drops_modules_that_are_now_out_of_scope(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The consequence of making faculty editable, so it is asserted here.

    Moving from Computing to Science leaves BIT 221 behind as a primary module the
    account can no longer act on. Kept, the profile would be making a claim about
    itself that is false; dropped, the onboarding gate asks for the new ones. The
    same rule as a university change clearing the faculty one step up.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "bit.switcher@must.ac.ug"
    )
    chosen = await committed_env.client.patch(
        "/v1/users/me",
        headers=bearer(body),
        json={"primary_course_unit_ids": [str(pilot["own_unit"].public_id)]},
    )
    assert chosen.status_code == 200, chosen.text
    assert chosen.json()["primary_course_unit_ids"] == [
        str(pilot["own_unit"].public_id)
    ]

    moved = await committed_env.client.patch(
        "/v1/users/me",
        headers=bearer(body),
        json={"faculty_id": str(pilot["other"].public_id)},
    )

    assert moved.status_code == 200, moved.text
    assert moved.json()["faculty_id"] == str(pilot["other"].public_id)
    assert moved.json()["primary_course_unit_ids"] == []


# --- discovery -------------------------------------------------------------


async def test_the_rail_shows_only_your_own_faculty(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """A Science tutor is absent from a Computing student's rail.

    Not ranked lower -- absent. The student cannot ask them for help in any course
    they take, so listing them offers a conversation with no course in it.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "rail.student@must.ac.ug"
    )
    own_tutor = await _tutor_in(
        committed_env, pilot, pilot["own"], pilot["own_unit"], "bit.tutor@must.ac.ug"
    )
    await _tutor_in(
        committed_env,
        pilot,
        pilot["other"],
        pilot["other_unit"],
        "sci.tutor@must.ac.ug",
    )

    response = await committed_env.client.get("/v1/tutors/top", headers=bearer(body))

    assert response.status_code == 200, response.text
    listed = [entry["user_id"] for entry in response.json()]
    assert listed == [str(own_tutor.public_id)]


async def test_the_rail_for_another_faculty_unit_is_empty_not_an_error(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """A stale picker value yields an empty rail, never a 4xx.

    Same reasoning as the catalogue: the client asked about a unit it believed
    existed for it, and an empty shortlist is the honest answer. A refusal would
    put the discovery screen into an error state over a value the student cannot
    fix from where they are.
    """
    body, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "rail.filter@must.ac.ug"
    )
    await _tutor_in(
        committed_env,
        pilot,
        pilot["other"],
        pilot["other_unit"],
        "sci.tutor2@must.ac.ug",
    )

    response = await committed_env.client.get(
        "/v1/tutors/top",
        headers=bearer(body),
        params={"course_unit_id": str(pilot["other_unit"].public_id)},
    )

    assert response.status_code == 200, response.text
    assert response.json() == []


async def test_a_tutor_detail_is_still_reachable_across_faculties(
    committed_env: CommittedEnv, pilot: dict
) -> None:
    """The one surface deliberately left open, asserted so it stays deliberate.

    A shared profile link has to work, or a tutor who sends their own page to a
    student in another faculty cannot. Signed in, as every other surface is --
    "open" here means the faculty silo does not govern reading a person, not that
    the page is public. It publishes nothing the tutor did not choose to show,
    which is why the rail can be a boundary while this is not.
    """
    reader, _ = await _in_faculty(
        committed_env, pilot, pilot["own"], "detail.reader@must.ac.ug"
    )
    tutor = await _tutor_in(
        committed_env,
        pilot,
        pilot["other"],
        pilot["other_unit"],
        "sci.tutor3@must.ac.ug",
    )

    response = await committed_env.client.get(
        f"/v1/tutors/{tutor.public_id}", headers=bearer(reader)
    )

    assert response.status_code == 200, response.text
    assert response.json()["profile"]["user_id"] == str(tutor.public_id)
