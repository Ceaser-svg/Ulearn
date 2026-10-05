"""Writes must survive the request that made them.

Every other HTTP test in this suite uses a fixture handing every request one
shared database session. That fixture is convenient -- a test can stage rows and
read them back without thinking about transactions -- but it has a consequence
worth stating plainly:

A service that adds a row and flushes it, but never commits, still looks correct
under that fixture. The flush is visible to the next request because it is handed
the same open transaction. Production does not work that way. `get_db` opens a
session per request and closes it at the end, so a write that was never committed
is rolled back on the way out.

The consequence is that the suite can be entirely green while the product does not
work at all. That is not hypothetical: `matching_service`, `session_service`,
`validation_service` and `rating_service` each `db.add(...)` + `flush()` and
return. The help-request flow a student actually performs returned 201 and then
404'd on the next request, because the row had been rolled back.

These tests use `committed_env.client`, where each request gets its own session, so
an uncommitted write is gone by the time the next request arrives. They assert
what a real client observes rather than what a fixture makes visible.
"""

from tests.conftest import CommittedEnv
from tests.support import bearer, complete_profile, first_course_unit, register


async def test_a_help_request_survives_the_request_that_created_it(
    committed_env: CommittedEnv,
) -> None:
    """The core loop: ask for help, then ask again in a later request.

    Registration commits, so its row survives and the harness itself is sound. Had
    registration not persisted either, this test would fail for a different reason
    and the failure would be much harder to read.
    """
    course_unit = await first_course_unit(committed_env)
    student = await register(
        committed_env.client, "persistence.student@student.mak.ac.ug"
    )
    await complete_profile(committed_env.client, student, course_unit=course_unit)

    created = await committed_env.client.post(
        "/v1/matching/help-requests",
        headers=bearer(student),
        json={
            "course_unit_id": course_unit["id"],
            "topic": "Eigenvalues and diagonalisation",
        },
    )
    assert created.status_code == 201, created.text
    request_id = created.json()["id"]

    # A separate request with a separate session, exactly as the app's next
    # screen load would issue it.
    fetched = await committed_env.client.get(
        f"/v1/matching/help-requests/{request_id}", headers=bearer(student)
    )
    assert fetched.status_code == 200, (
        "the help request did not survive its own request; re-reading it "
        f"returned {fetched.status_code}"
    )
    assert fetched.json()["id"] == request_id


async def test_a_created_help_request_is_listed_back(
    committed_env: CommittedEnv,
) -> None:
    """The same fact, observed the way the student's own list screen sees it."""
    course_unit = await first_course_unit(committed_env)
    student = await register(
        committed_env.client, "persistence.lister@student.mak.ac.ug"
    )
    await complete_profile(committed_env.client, student, course_unit=course_unit)

    created = await committed_env.client.post(
        "/v1/matching/help-requests",
        headers=bearer(student),
        json={
            "course_unit_id": course_unit["id"],
            "topic": "Proof technique by induction",
        },
    )
    assert created.status_code == 201, created.text

    listed = await committed_env.client.get(
        "/v1/matching/help-requests/me", headers=bearer(student)
    )
    assert listed.status_code == 200, listed.text
    assert [item["id"] for item in listed.json()] == [created.json()["id"]]
