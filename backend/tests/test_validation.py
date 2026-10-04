"""Tutor validation: what a competency is, and who may decide it.

This file was a one-line docstring while the module it covers had a route that
returned 404 for every request it was given, a review handler that granted the
tutor role with no grade check, and a submission path that raised
`MissingGreenlet` while building its own response. None of it was visible from
the rest of the suite, because the shared test session happened to hold the rows
those lazy loads wanted.

The rules covered here are the ones that were missing or wrong:

  * an operator cannot verify a grade below the university's competency gate
  * a tutor cannot verify their own competency -- the route does not exist
"""

from app.models.enums import CompetencyStatus
from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    grade_named,
    register,
)


async def test_a_below_threshold_grade_cannot_be_verified_by_an_operator(
    committed_env: CommittedEnv,
) -> None:
    """MUST invariant 2 is a rule about the record, not about the console.

    The submission path refuses a grade below the university's competency gate, so
    an operator verifying one by hand would leave the two paths disagreeing about
    what `verified` means. Matching re-checks eligibility independently, so this
    is about the audit trail being true rather than about safety -- but a
    `verified` record for a D is a false claim sitting in the database, and it is
    the kind of false claim an audit is supposed to be able to rule out.
    """
    client = committed_env.client
    course_unit = await first_course_unit(client)
    grade_d = await grade_named(client, "D")

    tutor = await register(client, "threshold.tutor@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit_id=course_unit["id"])

    submitted = await client.post(
        "/v1/competencies",
        headers=bearer(tutor),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade_d["id"],
            "source": "transcript",
        },
    )
    assert submitted.status_code == 201, submitted.text
    competency_id = submitted.json()["id"]

    admin = await _admin(committed_env, "threshold.admin@peerpass.mak.ac.ug")
    refused = await client.patch(
        f"/v1/admin/competencies/{competency_id}/review",
        headers=bearer(admin),
        json={"status": CompetencyStatus.VERIFIED.value},
    )
    assert refused.status_code == 422, (
        "an operator was able to verify a grade below the competency gate"
    )

    # And it must still be pending afterwards, not quietly verified.
    still = await client.get(f"/v1/competencies/{competency_id}", headers=bearer(tutor))
    assert still.status_code == 200, still.text
    assert still.json()["status"] == CompetencyStatus.PENDING.value


async def test_a_tutor_cannot_verify_their_own_competency(
    committed_env: CommittedEnv,
) -> None:
    """There is no owner-review endpoint, and there must not be one.

    The route existed and was unreachable only because it filtered on the wrong id
    column. Had that been "fixed" without looking, the tutor could have marked
    their own submission verified -- which grants the tutor role -- with no grade
    check at all.

    This asserts the route is *gone* rather than merely unusable. A 403 would have
    been the wrong answer: it leaves the grant sitting one refactor away from
    being reachable.
    """
    client = committed_env.client
    course_unit = await first_course_unit(client)
    grade_a = await grade_named(client, "A")

    tutor = await register(client, "selfreview.tutor@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit_id=course_unit["id"])
    submitted = await client.post(
        "/v1/competencies",
        headers=bearer(tutor),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade_a["id"],
            "source": "transcript",
        },
    )
    competency_id = submitted.json()["id"]

    self_review = await client.patch(
        f"/v1/competencies/{competency_id}/review",
        headers=bearer(tutor),
        json={"status": CompetencyStatus.VERIFIED.value},
    )
    assert self_review.status_code == 404, (
        "the owner-review route is reachable; a tutor could grant themselves "
        "the tutor role"
    )


async def test_a_submitted_competency_survives_its_own_request(
    committed_env: CommittedEnv,
) -> None:
    """A competency that vanishes on submission is not cosmetic.

    It means a tutor never reaches the review queue, so the pilot's validation
    loop has nothing in it to review. This also covers the response builder's
    lazy loads: building a response from a freshly inserted row walked
    `course_unit.university.grading_scale` synchronously, which raised
    `MissingGreenlet` -- and only failed, because a shared session would have
    satisfied those loads from its identity map.
    """
    client = committed_env.client
    course_unit = await first_course_unit(client)
    grade_a = await grade_named(client, "A")

    tutor = await register(client, "persisting.tutor@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit_id=course_unit["id"])

    created = await client.post(
        "/v1/competencies",
        headers=bearer(tutor),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade_a["id"],
            "source": "transcript",
            "evidence_reference": "Semester 5 transcript, page 2",
        },
    )
    assert created.status_code == 201, created.text

    fetched = await client.get(
        f"/v1/competencies/{created.json()['id']}", headers=bearer(tutor)
    )
    assert fetched.status_code == 200, (
        f"re-reading the competency returned {fetched.status_code}"
    )
    assert fetched.json()["id"] == created.json()["id"]


async def _admin(env: CommittedEnv, email: str) -> dict:
    from tests.support import grant_admin

    return await grant_admin(env, email)
