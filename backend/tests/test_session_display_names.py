"""A session card has to be able to name its people and its unit.

The session detail screen used to render `session.courseUnitId` and the other
party's public id straight into its "Course unit" and "Tutor"/"Student" rows. The
API returned those ids and nothing else to label them with, so a booked session
showed a student two UUIDs where a name and a course code belonged. The screen
even documented the shortfall -- "Adding a name to `SessionResponse` is a
one-field change on the API" -- and the change was never made, so it shipped.

Two properties are asserted, and the second is the one that matters:

* the names are present and populated, and
* they belong to the party they claim to.

`complete_profile` sets every account's name to the same "Loop Tester", so a
builder that swapped the two names would still satisfy `tutee_name` and
`tutor_name` being non-null. Each account is therefore renamed here to something
unmistakable, and each assertion checks the *other* party's name appears under
the right key.
"""

from httpx import AsyncClient

from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    register,
    scheduled_session,
    verified_tutor,
)

#: The display fields a session card reads. The ids stay on the wire as well --
#: they are what the client identifies records by -- so this is an addition, and
#: a response carrying only these would have broken every existing caller.
DISPLAY_KEYS = {
    "course_unit_code",
    "course_unit_name",
    "tutee_name",
    "tutor_name",
}

TUTEE_NAME = "Adongo Sarah Namutebi"
TUTOR_NAME = "Okello Daniel Mugisha"


async def _rename(client: AsyncClient, account: dict, full_name: str) -> None:
    response = await client.patch(
        "/v1/users/me", headers=bearer(account), json={"full_name": full_name}
    )
    assert response.status_code == 200, response.text


async def test_a_session_names_its_unit_and_both_parties(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)

    student = await register(committed_client, "sess-names-student@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)
    await _rename(committed_client, student, TUTEE_NAME)

    tutor = await verified_tutor(committed_env, "sess-names-tutor@peerpass.mak.ac.ug")
    await _rename(committed_client, tutor, TUTOR_NAME)

    session = await scheduled_session(committed_env, tutor, student, unit)

    listed = await committed_client.get("/v1/sessions/me", headers=bearer(student))
    assert listed.status_code == 200, listed.text
    fetched = await committed_client.get(
        f"/v1/sessions/{session['id']}", headers=bearer(tutor)
    )
    assert fetched.status_code == 200, fetched.text

    # Both reads, because the list and the detail are separate code paths and the
    # card a tutor opens is the detail one.
    for bodies in (listed.json(), [fetched.json()]):
        assert bodies
        for body in bodies:
            assert set(body) >= DISPLAY_KEYS, body
            assert body["course_unit_code"] == unit["code"], body
            assert body["course_unit_name"] == unit["name"], body
            assert body["tutee_name"] == TUTEE_NAME, body
            assert body["tutor_name"] == TUTOR_NAME, body


async def test_a_help_request_names_its_unit_and_its_student(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """The tutor deciding whether to accept needs to know who is asking.

    Same defect as the session card, one screen earlier: the request list gave a
    tutor a topic and a description and no way to tell which unit the question is
    about.
    """
    unit = await first_course_unit(committed_env)
    student = await register(committed_client, "req-names-student@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)
    await _rename(committed_client, student, TUTEE_NAME)

    created = await committed_client.post(
        "/v1/matching/help-requests",
        headers=bearer(student),
        json={"course_unit_id": unit["id"], "topic": "Eigenvalues"},
    )
    assert created.status_code == 201, created.text
    body = created.json()

    assert body["course_unit_code"] == unit["code"], body
    assert body["course_unit_name"] == unit["name"], body
    assert body["tutee_name"] == TUTEE_NAME, body
    # Unmatched yet: there is no tutor to name, and None is the honest answer
    # rather than a placeholder that reads like a real name.
    assert body["matched_tutor_id"] is None, body
    assert body["matched_tutor_name"] is None, body
