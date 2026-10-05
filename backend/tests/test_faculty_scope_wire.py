"""The faculty silo as a client meets it: real requests, real router, real guard.

`tests/test_faculty_scope.py` covers the rules against the services directly,
which is where the rules live but not where they are reached. Everything below
goes through the assembled application -- the router, the dependency wiring and
the auth guard included -- because each of those is a way for a rule that is
correct in its service to still not happen on the wire. A route that forgot to
declare its dependency, a guard that let an anonymous caller past, a serialiser
that dropped the field the client needs: none of those are visible to a test that
calls the service function.

These are the assertions the Flutter client depends on. The app resolves a
faculty by asking for the catalogue and then names units from what came back, so
if the scope were wrong here the client would quietly offer another faculty's
courses.
"""

from httpx import AsyncClient
from sqlalchemy import select

from app.models.course_unit import CourseUnit, Subject
from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    grade_named,
    grant_admin,
    register,
)

# Three faculties the pilot seed publishes units for: the one under test, a second
# unit-bearing one to prove the silo, and a third that is only ever used as
# "somewhere else". Named in a test rather than derived so that a change to the
# seed fails here instead of quietly narrowing what is proved.
_UNIT_BEARING = "Faculty of Computing and Informatics Sciences"
_OTHER_UNIT_BEARING = "Faculty of Science"
_OTHER_FACULTY = "Faculty of Interdisciplinary Studies"


async def _public_id(env: CommittedEnv, name: str) -> str:
    async with env.session() as session:
        subject = await session.scalar(select(Subject).where(Subject.name == name))
        assert subject is not None, f"the seed needs a faculty named {name!r}"
        return str(subject.public_id)


async def _unit_in(env: CommittedEnv, faculty_name: str) -> str:
    async with env.session() as session:
        unit = await session.scalar(
            select(CourseUnit)
            .join(Subject, CourseUnit.subject_id == Subject.id)
            .where(Subject.name == faculty_name)
            .order_by(CourseUnit.code)
        )
        assert unit is not None, f"the seed needs a course unit under {faculty_name!r}"
        return str(unit.public_id)


async def test_the_catalogue_is_unreachable_without_a_token(
    committed_client: AsyncClient,
) -> None:
    """The catalogue needs a faculty, and a faculty needs an account.

    Universities and faculties stay public because the wizard offers them before
    an account has either. The catalogue cannot: it answers for exactly one
    faculty, and a signed-out caller has none to be answered for.
    """
    # The two endpoints the wizard reaches before it has a profile still work.
    universities = await committed_client.get("/v1/academics/universities")
    faculties = await committed_client.get("/v1/academics/universities")
    assert universities.status_code == 200
    assert faculties.status_code == 200

    anonymous = await committed_client.get("/v1/academics/course-units")

    assert anonymous.status_code == 401, anonymous.text


async def test_the_catalogue_returns_only_the_callers_faculty(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A signed-in student sees their own faculty's units and nobody else's."""
    body = await register(committed_client, "catalogue@must.ac.ug")
    unit = await first_course_unit(committed_env)
    await complete_profile(committed_client, body, course_unit=unit)

    response = await committed_client.get(
        "/v1/academics/course-units", headers=bearer(body)
    )

    assert response.status_code == 200, response.text
    returned = response.json()
    # Every unit comes back from the one faculty the account was placed in, and
    # the whole of that faculty is here rather than a single row -- a catalogue
    # that filtered to just the unit the profile declared would pass a weaker
    # version of this test.
    assert {row["subject_id"] for row in returned} == {unit["subject_id"]}
    assert len(returned) > 1, "the seeded faculty holds three units"


async def test_subject_id_cannot_widen_the_scope_the_server_set(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """The client-supplied filter may narrow the catalogue but never widen it.

    This is the assertion the silo exists for. `subject_id` is a convenience for
    the picker, and a client that sent another faculty's id must be answered with
    nothing rather than with that faculty's catalogue.
    """
    body = await register(committed_client, "narrowing@must.ac.ug")
    unit = await first_course_unit(committed_env)
    await complete_profile(committed_client, body, course_unit=unit)
    other_faculty = await _public_id(committed_env, _OTHER_FACULTY)

    response = await committed_client.get(
        "/v1/academics/course-units",
        headers=bearer(body),
        params={"subject_id": other_faculty},
    )

    assert response.status_code == 200, response.text
    assert response.json() == []


async def test_a_student_with_no_faculty_is_answered_with_an_empty_catalogue(
    committed_client: AsyncClient,
) -> None:
    """A registered-but-unfinished account is a normal caller, not an error.

    Sign-up collects an email and a password, so this is every account between
    registration and the second wizard step. It has no faculty to be scoped to,
    and `[]` is the honest answer rather than a 422 the student did nothing to
    cause.
    """
    body = await register(committed_client, "halfway@must.ac.ug")

    response = await committed_client.get(
        "/v1/academics/course-units", headers=bearer(body)
    )

    assert response.status_code == 200, response.text
    assert response.json() == []


async def test_declaring_another_facultys_unit_is_refused(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A module from outside the student's own faculty is refused, and named as such.

    Kept as a wire assertion because the client's onboarding wizard depends on the
    failure being a *validation* error it can show against the step. A 404 saying
    the unit "could not be found" would send the student hunting a typo in an id
    the app never showed them.
    """
    body = await register(committed_client, "borrower@must.ac.ug")
    mine = await first_course_unit(committed_env)
    await complete_profile(committed_client, body, course_unit=mine)
    foreign_unit = await _unit_in(committed_env, _OTHER_UNIT_BEARING)

    response = await committed_client.patch(
        "/v1/users/me",
        headers=bearer(body),
        json={"primary_course_unit_ids": [foreign_unit]},
    )

    assert response.status_code == 422, response.text
    detail = response.json()["detail"]
    assert "faculty" in detail.lower(), detail

    # And the refusal left the profile alone: a rejected step must not have
    # half-applied by clearing what was already declared.
    me = await committed_client.get("/v1/auth/me", headers=bearer(body))
    assert me.json()["primary_course_unit_ids"] == [mine["id"]]


async def test_changing_faculty_drops_the_declared_modules(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """The client's reason for warning that course units will be asked for again.

    The Flutter profile screen tells the student to expect another round of unit
    selection after changing faculty. That message is only honest if the modules
    really are gone, and it is only necessary if keeping them would break something
    -- which it would, because every endpoint that reads them is faculty-scoped.
    """
    body = await register(committed_client, "mover@must.ac.ug")
    unit = await first_course_unit(committed_env)
    await complete_profile(committed_client, body, course_unit=unit)
    assert unit["id"]

    moved = await _public_id(committed_env, _OTHER_FACULTY)
    response = await committed_client.patch(
        "/v1/users/me", headers=bearer(body), json={"faculty_id": moved}
    )

    assert response.status_code == 200, response.text
    profile = response.json()
    assert profile["faculty_id"] == moved
    assert profile["primary_course_unit_ids"] == []


async def test_the_tutor_rail_is_empty_for_another_facultys_unit(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A tutor who exists is still not offered to a student of another faculty.

    Arranged with a real verified tutor holding a real competency for a Science
    unit, so the `[]` below is the filter speaking and not an empty seed. Without
    that, "the rail returned a list" would pass in a world with no tutors at all
    and prove nothing about the silo.

    The answer is `[]` and not a 404: the unit exists and is readable, it is
    simply not the caller's to rail on. The client renders `[]` as an empty
    state, so an error here would put a discovery screen into a fault state over a
    stale picker value.
    """
    science_unit_id = await _unit_in(committed_env, _OTHER_UNIT_BEARING)
    science_unit = {
        "id": science_unit_id,
        "subject_id": await _public_id(committed_env, _OTHER_UNIT_BEARING),
    }

    tutor = await _tutor_competent_in(committed_env, science_unit)

    # The tutor is real and matchable, so a rail asked for the tutor's own unit
    # from a peer in the same faculty must find them.
    peer = await register(committed_client, "peer@must.ac.ug")
    await complete_profile(committed_client, peer, course_unit=science_unit)
    same_faculty = await committed_client.get(
        "/v1/tutors/top",
        headers=bearer(peer),
        params={"course_unit_id": science_unit_id},
    )
    assert same_faculty.status_code == 200, same_faculty.text
    assert [row["user_id"] for row in same_faculty.json()] == [tutor["user"]["id"]]

    # And a Computing student asking about the Science unit is told nothing.
    computing = await register(committed_client, "railer@must.ac.ug")
    await complete_profile(
        committed_client, computing, course_unit=await first_course_unit(committed_env)
    )
    other_faculty = await committed_client.get(
        "/v1/tutors/top",
        headers=bearer(computing),
        params={"course_unit_id": science_unit_id},
    )

    assert other_faculty.status_code == 200, other_faculty.text
    assert other_faculty.json() == []


async def _tutor_competent_in(env: CommittedEnv, course_unit: dict) -> dict:
    """A verified tutor holding a real competency for [course_unit]."""
    client = env.client
    grade = await grade_named(client, "A")
    tutor = await register(client, f"faculty.tutor.{course_unit['id'][:8]}@must.ac.ug")
    await complete_profile(client, tutor, course_unit=course_unit)

    competency = await client.post(
        "/v1/competencies",
        headers=bearer(tutor),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade["id"],
            "source": "transcript",
            "evidence_reference": "Semester 5 transcript",
        },
    )
    assert competency.status_code == 201, competency.text

    admin = await grant_admin(env, f"admin.for.{tutor['user']['email']}")
    review = await client.patch(
        f"/v1/admin/competencies/{competency.json()['id']}/review",
        headers=bearer(admin),
        json={"status": "verified"},
    )
    assert review.status_code == 200, review.text
    return tutor


async def test_the_catalogue_stays_reachable_after_a_persisted_round_trip(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """`GET /auth/me` reports the faculty the profile was just given.

    The app reads its own faculty from the session, and the session is seeded from
    `GET /auth/me`. A response that echoed the *previous* faculty here would leave
    a student who has just changed faculty being told to choose course units for
    the old one -- which is the failure the stale-relationship fix addresses, and
    the one that cannot be seen by reading the database instead of the response.
    """
    body = await register(committed_client, "roundtrip@must.ac.ug")
    unit = await first_course_unit(committed_env)
    await complete_profile(committed_client, body, course_unit=unit)
    other = await _public_id(committed_env, _OTHER_FACULTY)

    await committed_client.patch(
        "/v1/users/me", headers=bearer(body), json={"faculty_id": other}
    )
    me = await committed_client.get("/v1/auth/me", headers=bearer(body))

    assert me.status_code == 200, me.text
    assert me.json()["faculty_id"] == other
    assert me.json()["primary_course_unit_ids"] == []
