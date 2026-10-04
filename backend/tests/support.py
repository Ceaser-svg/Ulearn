"""Helpers shared by the tests that drive the API over HTTP.

Kept in one place rather than imported from a sibling test module: a test file
that another test file imports private names out of is a test file whose helpers
can be deleted by accident, and the wire tests here have enough in common
(register, complete the wizard, authorise a request) to be worth naming once.
"""

import uuid
from datetime import UTC, datetime, timedelta

from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.course_unit import CourseUnit, University
from app.models.enums import UserRole
from app.models.user import User, set_roles
from tests.conftest import CommittedEnv

GOOD_PASSWORD = "correct horse battery staple"


def bearer(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['tokens']['access_token']}"}


async def register(client: AsyncClient, email: str) -> dict:
    """Create an account and return its auth payload.

    Registration takes an email and a password and nothing else; the profile is
    filled in afterwards by `complete_profile`, which is the wizard a real user
    works through.
    """
    response = await client.post(
        "/v1/auth/register", json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 201, response.text
    return response.json()


async def grant_admin(env: CommittedEnv, email: str) -> dict:
    """Promote a registered account to admin.

    Written straight to the database because granting the first admin role is an
    operator bootstrap and deliberately has no endpoint: role assignment is not
    something a signed-in user can do to themselves. The operator CLI does the
    same thing; see `docs/MUST_Production_Readiness.md`.
    """
    admin = await register(env.client, email)
    async with env.session() as session:
        user = await session.scalar(select_user_by_email(email))
        assert user is not None
        await set_roles(session, user.id, {UserRole.STUDENT, UserRole.ADMIN})
        await session.commit()
    return admin


def select_user_by_email(email: str):
    from sqlalchemy import select

    return select(User).where(User.email == email)


async def sole_faculty_id(db: AsyncSession, university: University) -> uuid.UUID:
    """The one faculty a fixture institution has course units under.

    Most fixtures build a single-subject world, because that is the smallest thing
    that can exercise one rule. This reads that subject so a staged account can be
    placed in it, which is no longer optional housekeeping: an account with no
    faculty can list no course unit, ask for no help, and see no tutor, so a
    fixture that leaves `faculty_id` null now fails in whichever assertion happens
    to come first rather than in the fixture.

    Resolved through the units rather than through `Subject.university_id`, because
    fixtures attach a subject to a university by way of its course units and leave
    the back-reference null. Asserting a single subject rather than taking the
    first is deliberate: a fixture that quietly picked one of two faculties would
    make a test about the silo pass or fail on which row the database returned.
    """
    found = set(
        (
            await db.execute(
                select(CourseUnit.subject_id)
                .where(
                    CourseUnit.university_id == university.id,
                    CourseUnit.subject_id.is_not(None),
                )
                .distinct()
            )
        )
        .scalars()
        .all()
    )
    assert len(found) == 1, (
        f"expected {university.name} to have course units under exactly one "
        f"faculty, found {len(found)}; a fixture with two has to say which one "
        "the account belongs to"
    )
    return found.pop()


async def complete_profile(
    client: AsyncClient, body: dict, *, course_unit: dict
) -> None:
    """The onboarding wizard, in the order a real client performs it.

    A university is required before a help request or a competency, a faculty is
    required before any course unit can be listed at all, and consent is required
    before any transcript evidence, so all three are set here rather than left to
    each test to rediscover the dependency.

    `course_unit` is required rather than optional because the faculty is taken
    from it. That is not tidiness: it is what keeps the fixtures self-consistent
    after the course-unit endpoint became faculty-scoped. An account whose faculty
    disagreed with the unit it is handed would fail every matching assertion for a
    reason that has nothing to do with what the test is about, and the optional
    form made that failure a matter of argument order rather than a type error.
    """
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]
    assert course_unit["subject_id"] is not None, (
        "the suite needs a unit with a faculty"
    )
    payload: dict = {
        "full_name": "Loop Tester",
        "university_id": university_id,
        "faculty_id": course_unit["subject_id"],
        "academic_data_consented": True,
        "primary_course_unit_ids": [course_unit["id"]],
    }
    response = await client.patch("/v1/users/me", headers=bearer(body), json=payload)
    assert response.status_code == 200, response.text


async def first_course_unit(env: CommittedEnv) -> dict:
    """A seeded course unit, carrying the ids the API would have handed back.

    Read from the database rather than over HTTP, and that is a change of shape
    with a reason. `/v1/academics/course-units` is scoped to the caller's faculty,
    so it can only answer for an account that has already chosen one -- which is
    exactly the state a test needs *before* it can choose. Reading the seed lets
    this helper and `complete_profile` agree on a faculty without either of them
    having to be rewritten to discover one, and it is the same row the endpoint
    would return for that account.

    Ordered by code, so "the first unit" means here what it means over the wire.
    """
    from sqlalchemy import select
    from sqlalchemy.orm import selectinload

    from app.models.course_unit import CourseUnit

    async with env.session() as session:
        row = (
            (
                await session.execute(
                    select(CourseUnit)
                    .options(selectinload(CourseUnit.subject))
                    .order_by(CourseUnit.university_id, CourseUnit.code)
                )
            )
            .scalars()
            .first()
        )
        assert row is not None, "the suite needs at least one seeded course unit"
        return {
            "id": str(row.public_id),
            "code": row.code,
            "subject_id": str(row.subject.public_id) if row.subject else None,
        }


async def grade_named(client: AsyncClient, label: str) -> dict:
    grades = (await client.get("/v1/academics/grades")).json()
    return next(grade for grade in grades if grade["label"] == label)


def in_an_hour() -> str:
    return (datetime.now(UTC) + timedelta(hours=1)).isoformat()


async def verified_tutor(env: CommittedEnv, email: str) -> dict:
    """A registered account that is a *verified* tutor, via the real API path.

    Verification is what makes a tutor matchable, so any test that needs one
    needs this rather than a direct role write: `set_roles({TUTOR})` would leave
    the competency table empty and the tutor would be proposed for nothing. Goes
    through the same submit-competency-then-operator-approves sequence a person
    does.
    """
    client = env.client
    course_unit = await first_course_unit(env)
    grade = await grade_named(client, "A")

    tutor = await register(client, email)
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

    admin = await grant_admin(env, f"admin.for.{email}")
    review = await client.patch(
        f"/v1/admin/competencies/{competency.json()['id']}/review",
        headers=bearer(admin),
        json={"status": "verified"},
    )
    assert review.status_code == 200, review.text
    return tutor


async def scheduled_session(
    env: CommittedEnv, tutor: dict, student: dict, course_unit: dict
) -> dict:
    """Drive matching all the way to a created session, and return its payload.

    Stops at the handshake: the session comes back `scheduled` with a PIN issued,
    which is the state the PIN tests need to start from.
    """
    client = env.client
    request = await client.post(
        "/v1/matching/help-requests",
        headers=bearer(student),
        json={
            "course_unit_id": course_unit["id"],
            "topic": "Diagonalisation of symmetric matrices",
        },
    )
    assert request.status_code == 201, request.text
    request_id = request.json()["id"]

    matches = await client.post(
        f"/v1/matching/help-requests/{request_id}/matches",
        headers=bearer(student),
        json={"course_unit_id": course_unit["id"]},
    )
    assert matches.status_code == 200, matches.text

    tutor_id = (await client.get("/v1/auth/me", headers=bearer(tutor))).json()["id"]
    assert tutor_id in [
        item["tutor"]["user_id"] for item in matches.json()["candidates"]
    ], "the verified tutor was not proposed, so this arrangement proves nothing"

    selected = await client.post(
        f"/v1/matching/help-requests/{request_id}/select",
        headers=bearer(student),
        json={"candidate_tutor_id": tutor_id},
    )
    assert selected.status_code == 200, selected.text

    session = await client.post(
        "/v1/sessions",
        headers=bearer(tutor),
        json={
            "help_request_id": request_id,
            "course_unit_id": course_unit["id"],
            "topic": "Diagonalisation of symmetric matrices",
            "duration_minutes": 60,
            "scheduled_start": in_an_hour(),
        },
    )
    assert session.status_code == 201, session.text
    return session.json()
