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
