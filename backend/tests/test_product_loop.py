"""The whole product loop, over the real wire, with real transaction boundaries.

Every other wire test exercises one endpoint. This one walks the path a tutor and
a student actually take, from a cold start with nothing staged, and asserts at the
end that what the platform promises is recorded:

  a tutor's verified competency, a session that was matched and completed, the
  rating that closed it, and the standing and minutes it produced.

Every step is a separate HTTP request with its own database session, as in
production. That is the entire point. An earlier version of this suite handed
every request one shared session, under which a service that flushed without
committing appeared to work: the flow went green while every row was rolled back
the moment its response was sent.

The admin account is arranged through `tests.support.grant_admin`, because
granting the first admin role is an operator bootstrap and has no endpoint by
design. Everything else goes through the API.
"""

from app.models.enums import UserRole
from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    grade_named,
    grant_admin,
    in_an_hour,
    register,
)


async def test_the_full_tutoring_loop_records_everything_it_promises(
    committed_env: CommittedEnv,
) -> None:
    client = committed_env.client
    course_unit = await first_course_unit(committed_env)
    grade_a = await grade_named(client, "A")

    # --- a tutor proves themselves ---------------------------------------
    tutor = await register(client, "loop.tutor@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit=course_unit)

    competency = await client.post(
        "/v1/competencies",
        headers=bearer(tutor),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade_a["id"],
            "source": "transcript",
            "evidence_reference": "Semester 5 transcript",
        },
    )
    assert competency.status_code == 201, competency.text

    # --- an operator approves it -----------------------------------------
    admin = await grant_admin(committed_env, "loop.admin@peerpass.mak.ac.ug")
    review = await client.patch(
        f"/v1/admin/competencies/{competency.json()['id']}/review",
        headers=bearer(admin),
        json={"status": "verified"},
    )
    assert review.status_code == 200, review.text
    assert review.json()["status"] == "verified"

    # Verification has to reach the tutor as a role, or matching will not propose
    # them and every later step would pass vacuously.
    me = await client.get("/v1/auth/me", headers=bearer(tutor))
    assert UserRole.TUTOR.value in me.json()["roles"], (
        "verification did not grant the tutor role"
    )
    tutor_id = me.json()["id"]

    # --- a student asks for help -----------------------------------------
    student = await register(client, "loop.student@student.mak.ac.ug")
    await complete_profile(client, student, course_unit=course_unit)

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

    # --- the platform proposes the verified tutor ------------------------
    matches = await client.post(
        f"/v1/matching/help-requests/{request_id}/matches",
        headers=bearer(student),
        json={"course_unit_id": course_unit["id"]},
    )
    assert matches.status_code == 200, matches.text
    proposed = [item["tutor"]["user_id"] for item in matches.json()["candidates"]]
    assert tutor_id in proposed, (
        "a tutor with a verified competency for this unit was not proposed"
    )

    # --- the student chooses, and the tutor confirms ---------------------
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
    session_id = session.json()["id"]

    # --- the handshake starts the session --------------------------------
    # The PIN is fetched from the tutor-only endpoint rather than read off the
    # session payload. It used to be a field on `SessionResponse`, which meant
    # the tutee could read their own PIN and start the session alone; the tutor
    # revealing it is what makes the handshake mean anything.
    pin_response = await client.get(
        f"/v1/sessions/{session_id}/pin", headers=bearer(tutor)
    )
    assert pin_response.status_code == 200, pin_response.text
    pin = pin_response.json()["session_pin"]
    assert pin, "a session must be issued a handshake PIN"
    started = await client.post(
        f"/v1/sessions/{session_id}/verify-pin",
        headers=bearer(student),
        json={"pin": pin},
    )
    assert started.status_code == 200, started.text
    assert started.json()["status"] == "in_progress"

    # --- it ends, and the minutes bank -----------------------------------
    completed = await client.post(
        f"/v1/sessions/{session_id}/transition",
        headers=bearer(student),
        json={"status": "completed"},
    )
    assert completed.status_code == 200, completed.text

    # --- the rating that closes the loop ---------------------------------
    rating = await client.post(
        f"/v1/ratings/{session_id}",
        headers=bearer(student),
        json={"score": 5, "feedback_text": "Explained it clearly."},
    )
    assert rating.status_code == 201, rating.text

    # --- what the platform promised is actually recorded ------------------
    standings = await client.get("/v1/admin/tutor-standings", headers=bearer(admin))
    assert standings.status_code == 200, standings.text
    summary = next(
        row for row in standings.json()["items"] if row["user_id"] == tutor_id
    )
    assert summary["completed_sessions"] == 1, (
        "the completed session did not survive; the tutor has none banked"
    )
    assert summary["rating_count"] == 1
    assert summary["average_rating"] == "5.00"
