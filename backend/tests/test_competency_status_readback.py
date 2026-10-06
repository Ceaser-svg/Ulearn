"""The endpoint a tutor's whole view of their application depends on.

`GET /v1/competencies/me` is what the client's "my tutor applications" screen
reads, and it had no test at all -- no route, no service, no response shape. The
service behind it runs a `selectinload` set whose own comment records that
omitting part of it previously produced `MissingGreenlet` *while building its own
response*, and that under the suite's shared session fixture the failure did not
appear at all because the identity map already held the rows.

That is precisely the shape of bug this file is here to prevent, so it asserts
through the real router and checks:

* the caller sees their own claims and only their own,
* every display field a screen reads is present and populated,
* a rejection carries the reason the reviewer wrote, which is the only thing
  that makes a rejection actionable, and
* a rejected claim can be submitted again, while a pending or verified one
  cannot.
"""

import uuid

from httpx import AsyncClient

from app.models.enums import CompetencyStatus
from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    grade_named,
    grant_admin,
    register,
    verified_tutor,
)


async def _my_id(client: AsyncClient, account: dict) -> str:
    """The signed-in account's public id.

    Read from `/v1/auth/me` rather than the registration payload, because the
    registration body carries tokens and not the identity -- and the identity is
    what `user_id` on a competency is compared against.
    """
    me = await client.get("/v1/auth/me", headers=bearer(account))
    assert me.status_code == 200, me.text
    return me.json()["id"]


async def _submit(
    client: AsyncClient,
    account: dict,
    course_unit: dict,
    grade: dict,
    *,
    evidence: str = "Semester 5 transcript",
) -> dict:
    response = await client.post(
        "/v1/competencies",
        headers=bearer(account),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade["id"],
            "source": "transcript",
            "evidence_reference": evidence,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def _review(
    client: AsyncClient,
    admin: dict,
    competency_id: str,
    **decision: object,
) -> None:
    response = await client.patch(
        f"/v1/admin/competencies/{competency_id}/review",
        headers=bearer(admin),
        json=decision,
    )
    assert response.status_code == 200, response.text


async def test_a_fresh_submission_reads_back_as_pending_and_labelled(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "A")
    student = await register(committed_client, "me-pending@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)

    await _submit(committed_client, student, unit, grade)

    mine = await committed_client.get("/v1/competencies/me", headers=bearer(student))
    assert mine.status_code == 200, mine.text
    assert len(mine.json()) == 1, mine.json()
    body = mine.json()[0]

    assert body["status"] == "pending", body
    # The fields the applications screen reads. Present *and* populated: an
    # assertion that only checked the keys would pass against a builder that
    # returned nulls, which renders no better than the ids it replaced.
    assert body["course_unit_code"] == unit["code"], body
    assert body["course_unit_name"] == unit["name"], body
    assert body["grade_label"] == "A", body
    # `meets_threshold` is false for a pending claim by design -- it reports
    # verified eligibility, and a claim no reviewer has approved is not
    # eligible however good the grade. Pinned so a later "fix" to make it true
    # would have to be deliberate.
    assert body["meets_threshold"] is False, body
    assert body["rejection_reason"] is None, body


async def test_the_caller_sees_their_own_claims_and_nobody_elses(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "A")
    mine = await register(committed_client, "me-scope-mine@peerpass.mak.ac.ug")
    await complete_profile(committed_client, mine, course_unit=unit)
    theirs = await register(committed_client, "me-scope-theirs@peerpass.mak.ac.ug")
    await complete_profile(committed_client, theirs, course_unit=unit)

    await _submit(committed_client, mine, unit, grade)
    await _submit(committed_client, theirs, unit, grade)

    listed = await committed_client.get("/v1/competencies/me", headers=bearer(mine))
    assert listed.status_code == 200, listed.text
    ids = {item["id"] for item in listed.json()}
    assert len(ids) == 1, listed.json()
    mine_id = await _my_id(committed_client, mine)
    theirs_id = await _my_id(committed_client, theirs)
    assert mine_id != theirs_id
    assert all(item["user_id"] == mine_id for item in listed.json()), listed.json()


async def test_a_rejection_travels_back_to_the_tutor_with_its_reason(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """The whole point of a rejection reason: the tutor has to be able to act.

    Without the reason on this response a tutor cannot tell an unfixable grade
    from a fixable one, and the runbook's requirement that a rejection carry "a
    clear, non-sensitive reason the tutor can act on" would not reach them.
    """
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "B+")
    student = await register(committed_client, "me-rejected@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)
    claim = await _submit(committed_client, student, unit, grade)
    admin = await grant_admin(committed_env, "admin.me-rejected@peerpass.mak.ac.ug")

    reason = "The transcript reference does not name the course. Add the unit code."
    await _review(
        committed_client,
        admin,
        claim["id"],
        status=CompetencyStatus.REJECTED.value,
        rejection_reason=reason,
    )

    mine = await committed_client.get("/v1/competencies/me", headers=bearer(student))
    assert mine.status_code == 200, mine.text
    body = mine.json()[0]
    assert body["status"] == "rejected", body
    assert body["rejection_reason"] == reason, body
    # Still false after rejection: rejected is not eligible either.
    assert body["meets_threshold"] is False, body


async def test_a_verified_claim_reads_back_as_verified(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "A")
    student = await register(committed_client, "me-verified@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)
    claim = await _submit(committed_client, student, unit, grade)
    admin = await grant_admin(committed_env, "admin.me-verified@peerpass.mak.ac.ug")
    await _review(
        committed_client, admin, claim["id"], status=CompetencyStatus.VERIFIED.value
    )

    mine = await committed_client.get("/v1/competencies/me", headers=bearer(student))
    assert mine.status_code == 200, mine.text
    body = mine.json()[0]
    assert body["status"] == "verified", body
    assert body["meets_threshold"] is True, body
    assert body["verified_at"] is not None, body
    assert body["rejection_reason"] is None, body


async def test_a_rejected_claim_can_be_submitted_again(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A rejection the tutor cannot answer is a permanent dead end.

    The duplicate guard used to match on `(user_id, course_unit_id)` alone, so a
    rejected claim blocked resubmission forever: the tutor read the reason and
    could do nothing about it, for that unit, ever.
    """
    unit = await first_course_unit(committed_env)
    rejected_grade = await grade_named(committed_client, "C")
    good_grade = await grade_named(committed_client, "A")
    student = await register(committed_client, "me-retry@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)
    claim = await _submit(committed_client, student, unit, rejected_grade)
    admin = await grant_admin(committed_env, "admin.me-retry@peerpass.mak.ac.ug")
    await _review(
        committed_client,
        admin,
        claim["id"],
        status=CompetencyStatus.REJECTED.value,
        rejection_reason="That grade is below the bar. Resubmit your coursework grade.",
    )

    # The same unit, a corrected grade, better evidence.
    resubmitted = await _submit(
        committed_client,
        student,
        unit,
        good_grade,
        evidence="Coursework mark sheet, unit code included",
    )
    assert resubmitted["status"] == "pending", resubmitted
    # The old reason is gone, or the tutor would read "resubmitted" and still be
    # told what was wrong with the proof they already replaced.
    assert resubmitted["rejection_reason"] is None, resubmitted
    assert resubmitted["grade_label"] == "A", resubmitted
    assert (
        resubmitted["evidence_reference"] == "Coursework mark sheet, unit code included"
    ), resubmitted
    # The same record, reopened -- not a second claim competing with the first.
    assert resubmitted["id"] == claim["id"], (claim, resubmitted)

    mine = await committed_client.get("/v1/competencies/me", headers=bearer(student))
    assert len(mine.json()) == 1, mine.json()


async def test_a_pending_claim_still_cannot_be_resubmitted(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """Reopening is for rejections only.

    A pending proof is already with a reviewer, and a second live claim for one
    unit would leave an operator choosing between them.
    """
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "A")
    student = await register(committed_client, "me-double@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)
    await _submit(committed_client, student, unit, grade)

    again = await committed_client.post(
        "/v1/competencies",
        headers=bearer(student),
        json={
            "course_unit_id": unit["id"],
            "grade_id": grade["id"],
            "source": "transcript",
            "evidence_reference": "Second attempt",
        },
    )
    assert again.status_code == 422, again.text


async def test_a_verified_claim_cannot_be_resubmitted(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A verified claim is the basis of a matching record; replacing it is a
    different question, and not one a submission form should answer."""
    tutor = await verified_tutor(committed_env, "me-verified-double@peerpass.mak.ac.ug")
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "A")

    again = await committed_client.post(
        "/v1/competencies",
        headers=bearer(tutor),
        json={
            "course_unit_id": unit["id"],
            "grade_id": grade["id"],
            "source": "transcript",
            "evidence_reference": "Trying to replace a verified claim",
        },
    )
    assert again.status_code == 422, again.text


async def test_the_list_needs_no_tutor_role(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A student with no claims gets an empty list, not a 403.

    The screen is shown to every signed-in user -- it is how they find out they
    have not applied yet -- so gating it on the tutor role would lock out exactly
    the person who needs to apply.
    """
    unit = await first_course_unit(committed_env)
    student = await register(committed_client, "me-empty@peerpass.mak.ac.ug")
    await complete_profile(committed_client, student, course_unit=unit)

    listed = await committed_client.get("/v1/competencies/me", headers=bearer(student))
    assert listed.status_code == 200, listed.text
    assert listed.json() == [], listed.json()


async def test_the_list_refuses_an_anonymous_caller(
    committed_client: AsyncClient,
) -> None:
    """The route is authenticated, so a guess at a unit id cannot walk claims."""
    listed = await committed_client.get("/v1/competencies/me")
    assert listed.status_code == 401, listed.text


async def test_the_list_rejects_a_malformed_public_id_shape(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """A non-uuid course unit id is a 422 rather than an empty list."""
    student = await register(committed_client, "me-malformed@peerpass.mak.ac.ug")
    unit = await first_course_unit(committed_env)
    await complete_profile(committed_client, student, course_unit=unit)

    listed = await committed_client.get(
        f"/v1/competencies/me?course_unit_id={uuid.uuid4()}",
        headers=bearer(student),
    )
    # The endpoint takes no parameters, so an unknown query string is ignored
    # rather than being a way to widen the scope.
    assert listed.status_code == 200, listed.text
    assert listed.json() == [], listed.json()
