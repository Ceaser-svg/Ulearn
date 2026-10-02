"""Helpers shared by the tests that drive the API over HTTP.

Kept in one place rather than imported from a sibling test module: a test file
that another test file imports private names out of is a test file whose helpers
can be deleted by accident, and the wire tests here have enough in common
(register, complete the wizard, authorise a request) to be worth naming once.
"""

from datetime import UTC, datetime, timedelta

from httpx import AsyncClient

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


async def complete_profile(
    client: AsyncClient, body: dict, *, course_unit_id: str | None = None
) -> None:
    """The onboarding wizard, in the order a real client performs it.

    A university is required before a help request or a competency, and consent is
    required before any transcript evidence, so both are set here rather than left
    to each test to rediscover the dependency.
    """
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]
    payload: dict = {
        "full_name": "Loop Tester",
        "university_id": university_id,
        "academic_data_consented": True,
    }
    if course_unit_id is not None:
        payload["primary_course_unit_ids"] = [course_unit_id]
    response = await client.patch("/v1/users/me", headers=bearer(body), json=payload)
    assert response.status_code == 200, response.text


async def first_course_unit(client: AsyncClient) -> dict:
    response = await client.get("/v1/academics/course-units")
    assert response.status_code == 200, response.text
    units = response.json()
    assert units, "the suite needs at least one seeded course unit"
    return units[0]


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
    course_unit = await first_course_unit(client)
    grade = await grade_named(client, "A")

    tutor = await register(client, email)
    await complete_profile(client, tutor, course_unit_id=course_unit["id"])

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
