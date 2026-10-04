"""The handshake PIN belongs to one party, and it is throttled.

The rule, which was inverted in both the API and the client: **the tutor reveals
the PIN, the tutee enters it.** It was the other way round. The tutee held the
digits and the tutor typed them, which means the tutor was proving nothing, and
`SessionResponse` carried `session_pin` for both parties, so a tutee could skip
the tutor entirely: read the PIN from their own session detail, POST it, and
start the session alone.

The throttle matters as much as the ownership. The PIN is two digits, so the
whole search space is 100 values; without an attempt ceiling `verify-pin` is a
free oracle. The counter lives on the row, committed, because an in-process
counter is cleared by a restart and is per-worker, and so is weakest exactly
when the service is under load and most worth attacking.
"""

import uuid
from datetime import timedelta

import pytest
from sqlalchemy import select

from app.models.session import Session
from app.services.session_service import MAX_PIN_ATTEMPTS, PIN_LOCKOUT
from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    register,
    scheduled_session,
    verified_tutor,
)


@pytest.fixture
async def handshake(committed_env: CommittedEnv) -> dict:
    """A scheduled session with a tutor, a tutee, and the PIN already read.

    The PIN is fetched from the tutor-only endpoint rather than off the session
    payload, because that is now the only way to get it, so the arrangement
    exercises the real rule rather than asserting against a fixture that has it
    pre-loaded.
    """
    client = committed_env.client
    course_unit = await first_course_unit(client)

    tutor = await verified_tutor(committed_env, "pin.tutor@peerpass.mak.ac.ug")
    student = await register(client, "pin.student@student.mak.ac.ug")
    await complete_profile(client, student)

    session = await scheduled_session(committed_env, tutor, student, course_unit)

    reveal = await client.get(
        f"/v1/sessions/{session['id']}/pin", headers=bearer(tutor)
    )
    assert reveal.status_code == 200, reveal.text

    return {
        "env": committed_env,
        "client": client,
        "session_id": session["id"],
        "pin": reveal.json()["session_pin"],
        "tutor": tutor,
        "student": student,
    }


async def _enter(ctx: dict, pin: str, *, who: str = "student"):
    return await ctx["client"].post(
        f"/v1/sessions/{ctx['session_id']}/verify-pin",
        headers=bearer(ctx[who]),
        json={"pin": pin},
    )


async def _wrong(ctx: dict, count: int) -> None:
    correct = ctx["pin"]
    candidate = "00" if correct != "00" else "01"
    for _ in range(count):
        assert (await _enter(ctx, candidate)).status_code == 422


async def _session_row(ctx: dict, db) -> Session:
    result = await db.execute(
        select(Session).where(Session.public_id == uuid.UUID(str(ctx["session_id"])))
    )
    return result.scalar_one()


# --- who may see the PIN ---------------------------------------------------


async def test_the_tutee_cannot_read_the_pin(handshake: dict) -> None:
    """The tutee asking is the whole attack this rule exists to stop."""
    response = await handshake["client"].get(
        f"/v1/sessions/{handshake['session_id']}/pin",
        headers=bearer(handshake["student"]),
    )
    assert response.status_code == 403, response.text


async def test_the_tutor_can_read_the_pin(handshake: dict) -> None:
    response = await handshake["client"].get(
        f"/v1/sessions/{handshake['session_id']}/pin",
        headers=bearer(handshake["tutor"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["session_pin"] == handshake["pin"]
    assert len(body["session_pin"]) == 2
    assert body["attempts_remaining"] == MAX_PIN_ATTEMPTS


async def test_a_stranger_cannot_read_the_pin(
    handshake: dict, committed_env: CommittedEnv
) -> None:
    outsider = await register(committed_env.client, "pin.outsider@student.mak.ac.ug")
    response = await committed_env.client.get(
        f"/v1/sessions/{handshake['session_id']}/pin", headers=bearer(outsider)
    )
    assert response.status_code in (403, 404), response.text


@pytest.mark.parametrize("who", ["tutor", "student"])
async def test_the_shared_response_carries_no_pin(handshake: dict, who: str) -> None:
    """The assertion that catches the original bug with no argument needed.

    A PIN in a payload both parties can fetch means the tutee reads their own
    PIN off their own session screen and there is no handshake left.
    """
    response = await handshake["client"].get(
        f"/v1/sessions/{handshake['session_id']}", headers=bearer(handshake[who])
    )
    assert response.status_code == 200, response.text
    assert "session_pin" not in response.json()


# --- who may enter it ------------------------------------------------------


async def test_the_tutee_enters_the_pin_and_the_session_starts(
    handshake: dict,
) -> None:
    response = await _enter(handshake, handshake["pin"])
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "in_progress"


async def test_the_tutor_cannot_enter_the_pin_they_already_know(
    handshake: dict,
) -> None:
    """They have the digits on screen. Entering them proves nothing.

    Allowing it would also let a tutor start a session on behalf of a student who
    never arrived.
    """
    response = await _enter(handshake, handshake["pin"], who="tutor")
    assert response.status_code == 403, response.text


async def test_a_wrong_pin_does_not_start_the_session(handshake: dict) -> None:
    assert (await _enter(handshake, "00")).status_code == 422
    fetched = await handshake["client"].get(
        f"/v1/sessions/{handshake['session_id']}",
        headers=bearer(handshake["student"]),
    )
    assert fetched.json()["status"] == "scheduled"


# --- the transition bypass -------------------------------------------------


async def test_the_transition_route_can_no_longer_start_a_session(
    handshake: dict,
) -> None:
    """`POST /transition` used to be a second, unthrottled way to start one.

    It accepted a `pin` field and checked it inline, with no attempt counter, so
    all 100 candidates could be walked through it without ever touching the
    cooldown on `verify-pin`. That made the throttle decorative.
    """
    response = await handshake["client"].post(
        f"/v1/sessions/{handshake['session_id']}/transition",
        headers=bearer(handshake["student"]),
        json={"status": "in_progress", "pin": handshake["pin"]},
    )
    assert response.status_code == 422, response.text
    # `extra="forbid"` makes a client that still sends the field fail loudly
    # rather than quietly on a request that ignores it.
    assert "pin" in response.json()["errors"]


async def test_the_transition_route_refuses_in_progress_bare(handshake: dict) -> None:
    response = await handshake["client"].post(
        f"/v1/sessions/{handshake['session_id']}/transition",
        headers=bearer(handshake["student"]),
        json={"status": "in_progress"},
    )
    assert response.status_code == 422, response.text
    assert "verify-pin" in response.json()["errors"]["status"]


# --- throttling ------------------------------------------------------------


async def test_wrong_pins_are_counted_and_eventually_lock_the_tutee_out(
    handshake: dict,
) -> None:
    """Past the ceiling even the *correct* PIN is refused, until the wait is up.

    A lockout that only rejects wrong guesses is not a lockout.

    All `MAX_PIN_ATTEMPTS` wrong entries are evaluated and each reports 422: the
    tutee is entitled to the tries they were given. The lock is raised by the last
    of them and bites on the *next* request, so the refusal below is the sixth
    attempt rather than the fifth.
    """
    for attempt in range(1, MAX_PIN_ATTEMPTS + 1):
        response = await _enter(handshake, "00")
        assert response.status_code == 422, (attempt, response.text)

    locked = await _enter(handshake, "00")
    assert locked.status_code == 429, locked.text
    assert int(locked.json()["errors"]["retry_after_seconds"]) > 0

    correct = await _enter(handshake, handshake["pin"])
    assert correct.status_code == 429, correct.text


async def test_the_counter_survives_the_request_that_incremented_it(
    handshake: dict,
) -> None:
    """Counted on a committed row, not on a session that rolls back.

    The increment is on the error path, which is precisely where an uncommitted
    write disappears as `get_db` closes. A lockout whose counter resets on every
    request is no lockout.
    """
    await _wrong(handshake, 1)
    reveal = await handshake["client"].get(
        f"/v1/sessions/{handshake['session_id']}/pin",
        headers=bearer(handshake["tutor"]),
    )
    assert reveal.status_code == 200, reveal.text
    assert reveal.json()["attempts_remaining"] == MAX_PIN_ATTEMPTS - 1


async def test_a_correct_pin_resets_the_counter(handshake: dict) -> None:
    """A tutee who mistypes once and then succeeds is not left a try from a lockout."""
    await _wrong(handshake, 2)
    assert (await _enter(handshake, handshake["pin"])).status_code == 200

    async with handshake["env"].session() as db:
        row = await _session_row(handshake, db)
        assert row.pin_failed_attempts == 0
        assert row.pin_locked_until is None


async def test_the_lockout_expires(handshake: dict) -> None:
    """A cooldown, not a permanent lock: both parties are standing right there."""
    await _wrong(handshake, MAX_PIN_ATTEMPTS)
    assert (await _enter(handshake, handshake["pin"])).status_code == 429

    # Wind the stored unlock back rather than sleeping fifteen minutes through it.
    async with handshake["env"].session() as db:
        row = await _session_row(handshake, db)
        assert row.pin_locked_until is not None
        row.pin_locked_until = row.pin_locked_until - PIN_LOCKOUT - timedelta(seconds=1)
        await db.commit()

    response = await _enter(handshake, handshake["pin"])
    assert response.status_code == 200, response.text


# --- input handling --------------------------------------------------------


async def test_an_oversized_pin_is_a_field_error_not_a_wrong_pin(
    handshake: dict,
) -> None:
    """A client bug should be reported as a bad field, not as "wrong PIN"."""
    response = await handshake["client"].post(
        f"/v1/sessions/{handshake['session_id']}/verify-pin",
        headers=bearer(handshake["student"]),
        json={"pin": "123456"},
    )
    assert response.status_code == 422
    assert "pin" in response.json()["errors"]


async def test_a_missing_pin_field_is_rejected_rather_than_read_as_blank(
    handshake: dict,
) -> None:
    """The route took `dict[str, str]` and defaulted the pin to `""`.

    So a malformed body produced "incorrect PIN" and sent the user hunting for a
    typo they never made.
    """
    response = await handshake["client"].post(
        f"/v1/sessions/{handshake['session_id']}/verify-pin",
        headers=bearer(handshake["student"]),
        json={},
    )
    assert response.status_code == 422
    assert "pin" in response.json()["errors"]
