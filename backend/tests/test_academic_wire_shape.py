"""The JSON the client is owed, asserted on the bytes the router emits.

The grades endpoint broke tutor registration while every server-side test stayed
green. `grade_points` is a `Decimal`, which FastAPI serialises as a JSON *string*
so a `numeric(6,2)` value is not rounded on its way to a client that only
displays it, and the Flutter client had been reading it as a number. The client's
cast raised a `TypeError`, the repository reported the type error instead of the
unreadable body, and the grades list never loaded -- so the tutor screen could
not submit proof and no tutor could be registered.

Both halves of that were invisible to the tests that existed. The backend suite
read `grade["label"]`, a string either way, and the Flutter suite had no test at
all for the grades lookup, let alone one built from a real response body.

These assertions are about *shape*: that the decimals arrive as strings, and that
they arrive. A test that checked only that the values were correct would have
passed against the shape that broke the client.
"""

from httpx import AsyncClient

from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    grade_named,
    register,
)

EXPECTED_KEYS = {"id", "label", "grade_points", "max_points", "grading_scale_id"}


async def test_grades_serialise_decimals_as_json_strings(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    response = await committed_client.get("/v1/academics/grades")

    assert response.status_code == 200, response.text
    grades = response.json()
    assert grades, "the seed must publish a grading scale for these to exist"

    for grade in grades:
        assert set(grade) == EXPECTED_KEYS
        # A string, and never a JSON number. Pydantic would reject the response
        # if this changed, which is the point: the client's reader is written
        # against this shape and no other.
        assert isinstance(grade["grade_points"], str), grade
        assert isinstance(grade["max_points"], str), grade
        # And a parseable one, so "it is a string" is not satisfied by an empty
        # or malformed value.
        float(grade["grade_points"])


async def test_a_competency_response_reports_its_grade_the_same_way(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """The submit response carries the same decimal, for the same reason."""
    body = await register(committed_client, "decimal.wire@must.ac.ug")
    unit = await first_course_unit(committed_env)
    await complete_profile(committed_client, body, course_unit=unit)
    grade = await grade_named(committed_client, "A")

    response = await committed_client.post(
        "/v1/competencies",
        headers=bearer(body),
        json={
            "course_unit_id": unit["id"],
            "grade_id": grade["id"],
            "source": "transcript",
        },
    )

    assert response.status_code == 201, response.text
    competency = response.json()
    assert isinstance(competency["grade_points"], str), competency
    assert float(competency["grade_points"]) == 5.0
    # A freshly submitted proof is unverified, and an unverified competency never
    # clears the bar whatever its grade. Pinned because it is the one field in
    # this payload that looks wrong to anyone reading a transcript: an A that
    # reads as "did not meet the threshold".
    assert competency["meets_threshold"] is False
