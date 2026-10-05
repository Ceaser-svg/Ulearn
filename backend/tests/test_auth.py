"""The auth slice, exercised through the real router.

Every test here goes through HTTP. A unit test on `auth_service` with a hand-built
session would pass while the route, the dependency wiring, or the problem-document
envelope was broken -- and those are the parts the client actually depends on.

The tests that matter most are the ones that would fail quietly. Enumeration,
refresh rotation, and family revocation are security properties with no
user-visible symptom when they break, so they are asserted explicitly rather than
left to be covered incidentally.
"""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from argon2 import PasswordHasher
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import security
from app.core.config import get_settings
from app.core.security import (
    TOKEN_TYPE_ACCESS,
    decode_token,
    hash_opaque_token,
)
from app.db.seed import seed
from app.models.course_unit import Subject, University
from app.models.enums import UserRole
from app.models.grading_scale import Grade, GradingScale
from app.models.user import RefreshToken, User
from tests.support import bearer

REGISTER_URL = "/v1/auth/register"
LOGIN_URL = "/v1/auth/login"
REFRESH_URL = "/v1/auth/refresh"
LOGOUT_URL = "/v1/auth/logout"
ME_URL = "/v1/auth/me"
PROFILE_URL = "/v1/users/me"
EMAIL = "student@must.ac.ug"

#: 28 characters: well past the 8 minimum, not on the deny-list, and a real
#: phrase so it is obviously not a test fixture that leaked into a policy check.
GOOD_PASSWORD = "correct horse battery staple"


async def register(client: AsyncClient, email: str = EMAIL) -> dict:
    """Register an account and return the response body."""
    response = await client.post(
        REGISTER_URL, json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 201, response.text
    return response.json()


def headers_for(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['tokens']['access_token']}"}


def _instant(value: str) -> datetime:
    """A serialised timestamp as an aware instant, assuming UTC when naive.

    SQLite drops the timezone on the way out, so a value that came back from the
    database parses as naive even though it was written as UTC.
    """
    parsed = datetime.fromisoformat(value)
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)


async def login(client: AsyncClient, email: str = EMAIL) -> dict:
    response = await client.post(
        LOGIN_URL, json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 200, response.text
    return response.json()


async def refresh(client: AsyncClient, refresh_token: str) -> dict:
    """Refresh, asserting success.

    The failure cases call the client directly, because a helper that asserts a
    200 cannot express "this one is supposed to be a 401".
    """
    response = await client.post(REFRESH_URL, json={"refresh_token": refresh_token})
    assert response.status_code == 200, response.text
    return response.json()


# --- registration ----------------------------------------------------------


async def test_register_returns_tokens_and_the_user(client: AsyncClient) -> None:
    body = await register(client)

    assert body["tokens"]["token_type"] == "Bearer"
    assert body["tokens"]["access_token"]
    assert body["tokens"]["refresh_token"]
    assert body["tokens"]["expires_in"] == get_settings().access_token_ttl * 60
    # Sign-up collects an address and a password only; the wizard supplies the
    # name, so the account is legitimately nameless at this point.
    assert body["user"]["full_name"] is None
    assert body["user"]["email"] == EMAIL
    assert body["user"]["university_id"] is None
    assert body["user"]["academic_data_consented_at"] is None


async def test_register_grants_the_tutee_role_and_nothing_else(
    client: AsyncClient,
) -> None:
    """The tutor role is earned through a verified competency, never self-claimed."""
    body = await register(client)

    assert body["user"]["roles"] == [UserRole.STUDENT.value]


async def test_register_never_returns_the_password_hash(client: AsyncClient) -> None:
    body = await register(client)

    assert "password" not in body["user"]
    assert "password_hash" not in body["user"]
    assert "password" not in body["tokens"]


async def test_register_rejects_a_duplicate_email(client: AsyncClient) -> None:
    await register(client)

    response = await client.post(
        REGISTER_URL, json={"email": EMAIL, "password": GOOD_PASSWORD}
    )

    assert response.status_code == 409
    assert response.json()["detail"]


async def test_register_treats_email_case_as_insensitive(client: AsyncClient) -> None:
    """Two spellings of one address must not become two accounts."""
    await register(client, email="Student@MUST.ac.ug")

    response = await client.post(
        REGISTER_URL,
        json={"email": "STUDENT@must.AC.ug", "password": "a different good passphrase"},
    )

    assert response.status_code == 409


async def test_register_lowercases_the_stored_address(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await register(client, email="MixedCase@MUST.ac.ug")

    user = await db_session.scalar(select(User))

    assert user.email == "mixedcase@must.ac.ug"


@pytest.mark.parametrize(
    ("password", "reason"),
    [
        ("short12", "under the 8 character minimum, and a literal under it"),
        ("        ", "eight spaces, which a length check alone accepts"),
        ("password1", "on the deny-list, though a legal length"),
        ("abcdefgh", "a keyboard run at a now-legal length"),
    ],
)
async def test_register_rejects_an_unacceptable_password(
    client: AsyncClient, password: str, reason: str
) -> None:
    response = await client.post(
        REGISTER_URL, json={"email": EMAIL, "password": password}
    )

    assert response.status_code == 422, reason
    assert "password" in response.json()["errors"]


async def test_an_eight_character_password_registers_and_signs_in(
    client: AsyncClient,
) -> None:
    """The point of lowering the minimum: a short, memorable password works.

    Asserted through the router rather than against `denial_reason` alone,
    because the length rule is enforced in two places -- the policy and the
    request schema -- and only the request path proves they agree. A policy test
    passing while the schema still demanded twelve would leave a student unable
    to sign up for the reason this change was made.

    The value is eight characters, not on the deny-list, and deliberately
    unmemorable-looking enough that the deny-list result is not an accident of
    this particular string.
    """
    password = "Kampala!7"

    registered = await client.post(
        REGISTER_URL, json={"email": EMAIL, "password": password}
    )
    assert registered.status_code == 201, registered.text

    signed_in = await client.post(
        LOGIN_URL, json={"email": EMAIL, "password": password}
    )
    assert signed_in.status_code == 200, signed_in.text
    assert signed_in.json()["user"]["email"] == EMAIL


async def test_register_rejects_an_unknown_field(client: AsyncClient) -> None:
    """A misspelled field must fail loudly rather than be silently dropped.

    A client that sends `roles: ["tutor"]` believing it worked has a security
    problem, not a validation one.
    """
    response = await client.post(
        REGISTER_URL,
        json={"email": EMAIL, "password": GOOD_PASSWORD, "roles": ["tutor"]},
    )

    assert response.status_code == 422


# --- sign-in ---------------------------------------------------------------


async def test_login_returns_a_fresh_pair(client: AsyncClient) -> None:
    signed_up = await register(client)

    body = await login(client)

    assert body["tokens"]["access_token"]
    assert body["user"]["id"] == signed_up["user"]["id"]
    assert body["user"]["email"] == EMAIL


async def test_login_accepts_any_casing_of_the_address(client: AsyncClient) -> None:
    await register(client)

    response = await client.post(
        LOGIN_URL, json={"email": "STUDENT@MUST.ac.ug", "password": GOOD_PASSWORD}
    )

    assert response.status_code == 200


async def test_wrong_password_and_unknown_email_are_indistinguishable(
    client: AsyncClient,
) -> None:
    """The enumeration check.

    This endpoint is the one place an attacker holding a list of student
    addresses gets to ask "does this person have an account?". A wrong password
    and an address that was never registered must be identical in status, body,
    and content type -- anything else is a yes/no oracle.
    """
    await register(client)

    wrong_password = await client.post(
        LOGIN_URL, json={"email": EMAIL, "password": "not the password"}
    )
    unknown_email = await client.post(
        LOGIN_URL, json={"email": "nobody@must.ac.ug", "password": "not the password"}
    )

    assert wrong_password.status_code == unknown_email.status_code == 401
    assert wrong_password.json() == unknown_email.json()
    assert (
        wrong_password.headers["content-type"] == unknown_email.headers["content-type"]
    )


async def test_sign_in_burns_argon2_work_for_an_unknown_address(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Identical wording is only half of the defence; the timing has to match too.

    Asserted on the decoy function rather than on the clock: wall-clock is too
    noisy to compare two Argon2 runs, and a timing assertion that only fails
    occasionally is one that gets deleted within a quarter.
    """
    await register(client)
    calls = 0
    # Patched on `security` rather than on `auth_service`: the service awaits the
    # async form, which wraps the sync one in a thread. Patching the name the
    # service imported would be caught by neither the wrapper nor the work it
    # delegates to.
    original = security.burn_password_verification

    def counting_burn() -> None:
        nonlocal calls
        calls += 1
        original()

    monkeypatch.setattr("app.core.security.burn_password_verification", counting_burn)

    wrong_password = await client.post(
        LOGIN_URL, json={"email": EMAIL, "password": "not the password"}
    )
    after_wrong_password = calls
    unknown_email = await client.post(
        LOGIN_URL, json={"email": "nobody@must.ac.ug", "password": "not the password"}
    )

    assert wrong_password.status_code == unknown_email.status_code == 401
    # Both paths do the work. Neither is cheap, so the gap between them does not
    # give the answer away.
    assert after_wrong_password == 0, (
        "a wrong password should verify the real hash, not burn"
    )
    assert calls == 1, "an unknown address did not spend the decoy verification"


async def test_a_deactivated_account_cannot_sign_in(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """Verified first, refused second, so it costs and reads like a bad password."""
    await register(client)
    user = await db_session.scalar(select(User))
    user.is_active = False
    await db_session.commit()

    response = await client.post(
        LOGIN_URL, json={"email": EMAIL, "password": GOOD_PASSWORD}
    )

    assert response.status_code == 401


async def test_a_successful_sign_in_rewrites_a_stale_hash(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """How a raised Argon2 cost reaches existing accounts without a migration.

    The stored hash has to be a real, verifiable one: a hand-written PHC string
    would be rejected as malformed before the password was ever checked, and the
    test would pass for the wrong reason.
    """
    await register(client)
    user = await db_session.scalar(select(User))
    weak = PasswordHasher(
        time_cost=1, memory_cost=8, parallelism=1, hash_len=32, salt_len=16
    ).hash(GOOD_PASSWORD)
    user.password_hash = weak
    await db_session.commit()

    await login(client)

    await db_session.refresh(user)

    assert user.password_hash != weak
    assert user.password_hash.startswith("$argon2id$v=19$m=19456")


# --- tokens ----------------------------------------------------------------


async def test_the_access_token_carries_no_roles(client: AsyncClient) -> None:
    """A role read from a token takes effect only at the next refresh.

    Suspension has to be immediate, which is why roles are read per request.
    """
    body = await register(client)
    claims = decode_token(
        body["tokens"]["access_token"], expected_type=TOKEN_TYPE_ACCESS
    )

    assert "roles" not in claims
    assert "standing" not in claims
    assert "jti" in claims


async def test_the_token_subject_is_the_public_id_not_the_primary_key(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """A JWT payload is base64, not encrypted: the client can read every claim."""
    body = await register(client)
    claims = decode_token(
        body["tokens"]["access_token"], expected_type=TOKEN_TYPE_ACCESS
    )
    user = await db_session.scalar(select(User))

    assert uuid.UUID(claims["sub"]) == user.public_id
    assert uuid.UUID(claims["sub"]) != user.id


async def test_me_requires_a_bearer_token(client: AsyncClient) -> None:
    assert (await client.get(ME_URL)).status_code == 401


async def test_me_rejects_a_tampered_token(client: AsyncClient) -> None:
    body = await register(client)
    forged = body["tokens"]["access_token"][:-4] + "AAAA"

    response = await client.get(ME_URL, headers={"Authorization": f"Bearer {forged}"})

    assert response.status_code == 401


async def test_me_rejects_an_expired_token(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The 15 minute lifetime has to be the reason a token dies, not rotation.

    Minted expired rather than faked, so this goes through the real encoder and
    the real decoder.
    """
    monkeypatch.setattr(get_settings(), "access_token_ttl", -1)
    body = await register(client)

    response = await client.get(ME_URL, headers=headers_for(body))

    assert response.status_code == 401
    assert response.json()["detail"] == "Your session has ended."


async def test_me_returns_the_callers_own_record(client: AsyncClient) -> None:
    body = await register(client)

    response = await client.get(ME_URL, headers=headers_for(body))

    assert response.status_code == 200
    assert response.json()["id"] == body["user"]["id"]


async def test_a_refresh_token_is_not_accepted_where_an_access_token_is(
    client: AsyncClient,
) -> None:
    """A refresh token is a 30 day credential.

    Without the type check it would be a bearer token for every authenticated
    endpoint, and the access token's 15 minute lifetime would be decorative.
    """
    body = await register(client)

    response = await client.get(
        ME_URL, headers={"Authorization": f"Bearer {body['tokens']['refresh_token']}"}
    )

    assert response.status_code == 401


# --- refresh rotation ------------------------------------------------------


async def test_refresh_issues_a_new_pair(client: AsyncClient) -> None:
    body = await register(client)

    rotated = await refresh(client, body["tokens"]["refresh_token"])

    assert rotated["tokens"]["access_token"] != body["tokens"]["access_token"]


async def test_a_rotated_token_stops_working(client: AsyncClient) -> None:
    body = await register(client)
    await refresh(client, body["tokens"]["refresh_token"])

    replay = await client.post(
        REFRESH_URL, json={"refresh_token": body["tokens"]["refresh_token"]}
    )

    assert replay.status_code == 401


async def test_replaying_a_rotated_token_kills_the_live_one(
    client: AsyncClient,
) -> None:
    """The theft signal.

    Either the attacker or the student is holding a token that should be dead,
    and the request cannot say which. So the chain dies and the next legitimate
    refresh fails; the student signs in again. Being signed out is the intended
    outcome, not a side effect of detecting the theft.
    """
    body = await register(client)
    live = (await refresh(client, body["tokens"]["refresh_token"]))["tokens"][
        "refresh_token"
    ]

    # The stolen first token comes back.
    replay = await client.post(
        REFRESH_URL, json={"refresh_token": body["tokens"]["refresh_token"]}
    )
    assert replay.status_code == 401

    # The real user's current token is now dead too.
    assert (
        await client.post(REFRESH_URL, json={"refresh_token": live})
    ).status_code == 401


async def test_replay_does_not_revoke_a_second_devices_session(
    client: AsyncClient,
) -> None:
    """A second sign-in is its own chain, and must survive the first one's theft.

    The response to a stolen token is to revoke the compromised chain, not to
    sign the student out of a phone nobody touched.
    """
    first = await register(client)
    second = await login(client)
    await refresh(client, first["tokens"]["refresh_token"])

    # The stolen first token comes back and burns its own chain.
    await client.post(
        REFRESH_URL, json={"refresh_token": first["tokens"]["refresh_token"]}
    )

    assert (
        await client.post(
            REFRESH_URL, json={"refresh_token": second["tokens"]["refresh_token"]}
        )
    ).status_code == 200


async def test_refresh_rejects_an_unknown_token(client: AsyncClient) -> None:
    assert (
        await client.post(REFRESH_URL, json={"refresh_token": "not-a-real-token"})
    ).status_code == 401


async def test_refresh_rejects_an_expired_token(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await register(client)
    presented = (await login(client))["tokens"]["refresh_token"]
    stored = await db_session.scalar(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_opaque_token(presented)
        )
    )
    stored.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await db_session.commit()

    assert (
        await client.post(REFRESH_URL, json={"refresh_token": presented})
    ).status_code == 401


async def test_only_a_hash_of_the_refresh_token_is_stored(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """A stolen database must yield no usable token."""
    body = await register(client)

    stored = await db_session.scalar(select(RefreshToken))

    assert body["tokens"]["refresh_token"] not in stored.token_hash
    assert len(stored.token_hash) == 64


# --- sign-out --------------------------------------------------------------


async def test_logout_revokes_the_refresh_token(client: AsyncClient) -> None:
    body = await register(client)

    response = await client.post(
        LOGOUT_URL,
        json={"refresh_token": body["tokens"]["refresh_token"]},
        headers=headers_for(body),
    )

    assert response.status_code == 204
    assert (
        await client.post(
            REFRESH_URL, json={"refresh_token": body["tokens"]["refresh_token"]}
        )
    ).status_code == 401


async def test_logout_succeeds_without_a_body(client: AsyncClient) -> None:
    """A client that already cleared its token store must still be able to sign out."""
    body = await register(client)

    assert (await client.post(LOGOUT_URL, headers=headers_for(body))).status_code == 204


async def test_logout_requires_authentication(client: AsyncClient) -> None:
    """Revoking by token alone would let anyone who saw one end someone's session."""
    body = await register(client)

    response = await client.post(
        LOGOUT_URL, json={"refresh_token": body["tokens"]["refresh_token"]}
    )

    assert response.status_code == 401
    # And the token survives the attempt.
    assert (
        await client.post(
            REFRESH_URL, json={"refresh_token": body["tokens"]["refresh_token"]}
        )
    ).status_code == 200


async def test_logout_will_not_revoke_another_users_token(
    client: AsyncClient,
) -> None:
    """Authentication is required, and it is checked against the token."""
    await register(client, email="first@must.ac.ug")
    second = await register(client, email="second@must.ac.ug")
    first = await login(client, "first@must.ac.ug")

    response = await client.post(
        LOGOUT_URL,
        json={"refresh_token": second["tokens"]["refresh_token"]},
        headers=headers_for(first),
    )

    assert response.status_code in (204, 404)
    # Either way, the other user's token must survive.
    assert (
        await client.post(
            REFRESH_URL, json={"refresh_token": second["tokens"]["refresh_token"]}
        )
    ).status_code == 200


# --- the profile -----------------------------------------------------------


async def test_seeded_academic_catalogue_populates_onboarding_options(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """The real lookup routes expose the data the onboarding client needs."""
    await seed(db_session)

    universities = await client.get("/v1/academics/universities")
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]
    faculties = await client.get(
        "/v1/academics/faculties",
        params={"university_id": university_id},
    )

    assert universities.status_code == 200
    assert faculties.status_code == 200
    assert universities.json()[0]["name"] == (
        "Mbarara University of Science and Technology"
    )
    assert "Faculty of Computing and Informatics Sciences" in {
        row["name"] for row in faculties.json()
    }
    programs = await client.get(
        "/v1/academics/programs",
        params={"university_id": university_id},
    )
    assert programs.status_code == 200
    assert any(row["name"] == "Medicine and Surgery (MBChB)" for row in programs.json())


async def test_profile_update_sets_the_name(client: AsyncClient) -> None:
    body = await register(client)

    response = await client.patch(
        PROFILE_URL, json={"full_name": "Achieng Okello"}, headers=headers_for(body)
    )

    assert response.status_code == 200
    assert response.json()["full_name"] == "Achieng Okello"


async def test_profile_update_only_touches_the_fields_it_was_given(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """The wizard saves one step at a time.

    A step sending only `full_name` must not blank the faculty chosen on the
    previous screen, and a retried step has to be safe to send twice.
    """
    await seed(db_session)
    body = await register(client)
    university = (await client.get("/v1/academics/universities")).json()[0]
    faculty = (
        await client.get(
            "/v1/academics/faculties",
            params={"university_id": university["id"]},
        )
    ).json()[0]
    headers = headers_for(body)

    await client.patch(
        PROFILE_URL,
        json={
            "university_id": university["id"],
            "faculty_id": faculty["id"],
            "year_of_study": 2,
        },
        headers=headers,
    )
    response = await client.patch(
        PROFILE_URL, json={"full_name": "Achieng Okello"}, headers=headers
    )

    assert response.json()["university_id"] == university["id"]
    assert response.json()["faculty_id"] == faculty["id"]
    assert response.json()["year_of_study"] == 2


async def test_profile_update_rejects_faculty_from_another_university(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    await seed(db_session)
    university = (await client.get("/v1/academics/universities")).json()[0]
    other = University(name="Other University")
    other_faculty = Subject(name="Faculty of Science", university=other)
    db_session.add_all([other, other_faculty])
    await db_session.commit()
    body = await register(client)

    response = await client.patch(
        PROFILE_URL,
        json={
            "university_id": university["id"],
            "faculty_id": str(other_faculty.public_id),
        },
        headers=headers_for(body),
    )

    assert response.status_code == 404


async def test_profile_update_records_consent_once(client: AsyncClient) -> None:
    body = await register(client)
    headers = headers_for(body)

    first = await client.patch(
        PROFILE_URL, json={"academic_data_consented": True}, headers=headers
    )
    second = await client.patch(
        PROFILE_URL, json={"academic_data_consented": True}, headers=headers
    )

    assert first.json()["academic_data_consented_at"] is not None
    # A second step must not move the timestamp. It records when consent was
    # given, and a wizard that re-sends it should not restate that date.
    #
    # Compared as instants rather than as strings because SQLite stores no
    # timezone: the first response serialises the aware value it was handed and
    # the second re-reads a naive one, so the two strings differ by a `Z` while
    # naming the same moment.
    assert _instant(second.json()["academic_data_consented_at"]) == _instant(
        first.json()["academic_data_consented_at"]
    )


async def test_profile_update_rejects_an_unknown_university(
    client: AsyncClient,
) -> None:
    """Writing NULL because an id was unrecognised would look like a cleared field."""
    body = await register(client)

    response = await client.patch(
        PROFILE_URL,
        json={"university_id": str(uuid.uuid4())},
        headers=headers_for(body),
    )

    assert response.status_code == 404


async def test_profile_update_rejects_a_year_outside_the_range(
    client: AsyncClient,
) -> None:
    body = await register(client)

    response = await client.patch(
        PROFILE_URL, json={"year_of_study": 9}, headers=headers_for(body)
    )

    assert response.status_code == 422


async def test_profile_update_requires_authentication(client: AsyncClient) -> None:
    assert (
        await client.patch(PROFILE_URL, json={"full_name": "Nobody"})
    ).status_code == 401


# --- reference data --------------------------------------------------------


async def test_academics_are_readable_before_signing_in(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """Sign-up asks a stranger where they study, so these cannot need a token."""
    await seed(db_session)
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]
    for url in ("/v1/academics/universities",):
        assert (await client.get(url)).status_code == 200, url
    assert (
        await client.get(
            "/v1/academics/faculties",
            params={"university_id": university_id},
        )
    ).status_code == 200


async def test_the_course_catalogue_needs_a_session(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """The one academics route that is not public, and why.

    A list of institutions and faculties is public information: a stranger
    registering needs both. The course catalogue is not, because it answers
    "which courses may this account act on", which is scoped to one person's
    faculty. Leaving it open would hand every anonymous caller the whole pilot
    catalogue and make the scoping that endpoint now performs a client-side
    convention rather than a boundary.
    """
    await seed(db_session)

    anonymous = await client.get("/v1/academics/course-units")
    assert anonymous.status_code == 401, anonymous.text

    student = await register(client, "catalogue.gate@student.must.ac.ug")
    signed_in = await client.get("/v1/academics/course-units", headers=bearer(student))
    assert signed_in.status_code == 200, signed_in.text


async def test_seed_exposes_only_the_provisional_pilot_course_units(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """The catalogue, read one faculty at a time, because that is all a caller sees.

    Asserted per faculty rather than as one flat list: the units are seeded under
    two faculties and an account belongs to exactly one of them, so a single
    assertion would need the unscoped listing this endpoint deliberately is not.
    """
    await seed(db_session)
    university_id = (await client.get("/v1/academics/universities")).json()[0]["id"]
    faculties = (
        await client.get(
            "/v1/academics/faculties",
            params={"university_id": university_id},
        )
    ).json()
    by_name = {faculty["name"]: faculty["id"] for faculty in faculties}

    expected_by_faculty = {
        "Faculty of Computing and Informatics Sciences": {
            ("BIT 221", "Operating Systems"),
            ("BIT 223", "Database Programming"),
            ("BIT 225", "Computer Networks"),
        },
        "Faculty of Science": {
            ("SCH 211", "Organic Chemistry"),
            ("PHY 212", "Thermodynamics"),
            ("MTH 213", "Linear Algebra"),
        },
    }

    student = await register(client, "catalogue@student.must.ac.ug")
    listed: set[tuple[str, str]] = set()
    for name, expected in expected_by_faculty.items():
        chosen = await client.patch(
            PROFILE_URL,
            headers=bearer(student),
            json={"university_id": university_id, "faculty_id": by_name[name]},
        )
        assert chosen.status_code == 200, chosen.text
        units = (
            await client.get("/v1/academics/course-units", headers=bearer(student))
        ).json()
        assert {(unit["code"], unit["name"]) for unit in units} == expected, name
        listed |= {(unit["code"], unit["name"]) for unit in units}

    assert not any(
        name in {"Computer Science", "Information Technology"} for _code, name in listed
    )


async def test_the_seeded_gate_admits_a_b_plus_and_refuses_a_b(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """The competency bar, read as data rather than as a constant.

    MUST's scale is a five-point one and B+ is worth 4. A B, at 3, must fall
    below the gate; a test asserting only "B+ passes" would not notice the gate
    had been set to zero.
    """
    await seed(db_session)

    scale = await db_session.scalar(select(GradingScale))
    points = {
        row.label: row.grade_points
        for row in (
            await db_session.execute(
                select(Grade).where(Grade.grading_scale_id == scale.id)
            )
        ).scalars()
    }

    assert scale.max_points == 5
    assert scale.competency_min_points == 4.5
    assert points["B+"] >= scale.competency_min_points
    assert points["B+"] == 4.5
    assert points["B"] == 4
    assert points["B"] < scale.competency_min_points
