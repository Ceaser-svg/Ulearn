"""The review queue as an operator meets it, start to finish.

The other suites check each of these steps separately and against mocked
dependencies. This one walks the two paths a real pilot actually takes -- a claim
that is approved, and a claim that is refused and then resubmitted -- through the
real router, with each request in its own database session as production is.

The difference matters more than it sounds. A suite that hands every request one
shared session cannot tell a committed write from a flushed one, because the
flush stays visible in the next request's open transaction. Every assertion here
is about what a later request can actually see: the tutor's rail, the standing
that verification created, the audit entry naming the operator, the reason the
tutor was given. Anything not committed by the end of its request would leave a
green suite and a console that does nothing.

`committed_env` is the fixture that closes that gap, and it needs
`PEERPASS_TEST_DATABASE_URL` to be PostgreSQL for the run to mean the most. See
`AGENTS.md` section 9.
"""

from httpx import AsyncClient

from tests.conftest import CommittedEnv
from tests.support import (
    bearer,
    complete_profile,
    first_course_unit,
    grade_named,
    grant_admin,
    register,
)


async def _submit(
    client: AsyncClient,
    account: dict,
    course_unit: dict,
    grade: dict,
    *,
    evidence: str = "Semester 5 transcript",
) -> dict:
    """A tutor claims a unit, the way the mobile app does."""
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
    **decision: str,
) -> dict:
    response = await client.patch(
        f"/v1/admin/competencies/{competency_id}/review",
        headers=bearer(admin),
        json=decision,
    )
    assert response.status_code == 200, response.text
    return response.json()


async def _queue(client: AsyncClient, admin: dict, **params: str) -> dict:
    response = await client.get(
        "/v1/admin/competencies",
        params=params,
        headers=bearer(admin),
    )
    assert response.status_code == 200, response.text
    return response.json()


async def _row_for(client: AsyncClient, admin: dict, email: str) -> dict:
    """The queue's row for one tutor, read back over HTTP."""
    page = await _queue(client, admin)
    rows = [row for row in page["items"] if row["user_email"] == email]
    assert len(rows) == 1, f"expected one row for {email}, got {page}"
    return rows[0]


async def test_an_approved_claim_reaches_the_tutor_and_the_audit_log(
    committed_env: CommittedEnv,
) -> None:
    """Pending to verified, and every consequence the pilot relies on.

    Verification is the step that makes a tutor real: it grants the tutor role,
    creates the provisional profile, and puts the tutor in the rail. An approval
    that stops at a 200 would pass a unit test on the handler and leave the tutor
    unable to be matched at all.
    """
    client = committed_env.client
    course_unit = await first_course_unit(committed_env)
    grade_a = await grade_named(client, "A")

    # --- a tutor claims a unit they have an A in ----------------------------
    tutor = await register(client, "e2e.approved@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit=course_unit)
    claim = await _submit(client, tutor, course_unit, grade_a)

    # --- what the operator sees before deciding ---------------------------
    # The decision context, not a lookup the operator has to make first.
    admin = await grant_admin(committed_env, "e2e.approver@peerpass.mak.ac.ug")
    row = await _row_for(client, admin, "e2e.approved@student.mak.ac.ug")
    assert row["status"] == "pending", row
    assert row["grade_label"] == "A", row
    assert row["competency_min_points"], "the bar must be stated for the reviewer"
    assert row["meets_threshold"] is True, row
    assert row["evidence_reference"] == "Semester 5 transcript", row

    # --- an operator approves it ------------------------------------------
    reviewed = await _review(client, admin, claim["id"], status="verified")
    assert reviewed["status"] == "verified", reviewed
    assert reviewed["verified_at"], "an approval with no timestamp cannot be audited"

    # --- the tutor has the role verification promises ----------------------
    me = await client.get("/v1/auth/me", headers=bearer(tutor))
    assert "tutor" in me.json()["roles"], (
        f"verification did not grant the tutor role: {me.json()['roles']}"
    )

    # --- and a student in that faculty can actually be offered them --------
    student = await register(client, "e2e.asker@student.mak.ac.ug")
    await complete_profile(client, student, course_unit=course_unit)
    request = await client.post(
        "/v1/matching/help-requests",
        headers=bearer(student),
        json={"course_unit_id": course_unit["id"], "topic": "Diagonalisation"},
    )
    assert request.status_code == 201, request.text
    matches = await client.post(
        f"/v1/matching/help-requests/{request.json()['id']}/matches",
        headers=bearer(student),
        json={"course_unit_id": course_unit["id"]},
    )
    assert matches.status_code == 200, matches.text
    proposed = [item["tutor"]["user_id"] for item in matches.json()["candidates"]]
    assert me.json()["id"] in proposed, (
        "a verified tutor was not proposed for the unit they hold a verified "
        f"competency for: {matches.json()}"
    )

    # --- and the audit log says who did it ---------------------------------
    audit = await client.get(
        "/v1/admin/audit-events",
        headers=bearer(admin),
    )
    assert audit.status_code == 200, audit.text
    decisions = [
        event
        for event in audit.json()["items"]
        if event["target_public_id"] == claim["id"]
    ]
    assert decisions, "the review left no audit event"
    decision = decisions[0]
    assert decision["actor_email"] == "e2e.approver@peerpass.mak.ac.ug", (
        f"an audit event that does not name its operator is not an audit trail: "
        f"{decision}"
    )


async def test_a_refused_claim_gives_a_reason_the_tutor_can_act_on(
    committed_env: CommittedEnv,
) -> None:
    """Pending to rejected, and the reason survives to the tutor's own view.

    A rejection with no stated reason is a dead end: the tutor is told no without
    being told why, and the only thing they can do is submit the same thing again.
    """
    client = committed_env.client
    course_unit = await first_course_unit(committed_env)
    poor_grade = await grade_named(client, "D")

    tutor = await register(client, "e2e.refused@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit=course_unit)
    claim = await _submit(client, tutor, course_unit, poor_grade)

    # --- the operator is warned before they try --------------------------
    admin = await grant_admin(committed_env, "e2e.refuser@peerpass.mak.ac.ug")
    row = await _row_for(client, admin, "e2e.refused@student.mak.ac.ug")
    assert row["meets_threshold"] is False, (
        f"a grade under the bar must not be presented as approvable: {row}"
    )

    reason = (
        "The unit result page is missing from the reference you gave. "
        "Submit the full transcript page showing the result for this unit."
    )
    refused = await _review(
        client,
        admin,
        claim["id"],
        status="rejected",
        rejection_reason=reason,
    )
    assert refused["status"] == "rejected", refused
    assert refused["rejection_reason"] == reason, refused

    # --- the tutor is told, in their own app's terms ----------------------
    # A bare list, not a page: the tutor is looking at their own handful of
    # claims, so there is no pager to read.
    mine = await client.get("/v1/competencies/me", headers=bearer(tutor))
    assert mine.status_code == 200, mine.text
    mine_row = next(row for row in mine.json() if row["id"] == claim["id"])
    assert mine_row["status"] == "rejected", mine_row
    assert mine_row["rejection_reason"] == reason, (
        f"the tutor was not given the reason: {mine_row}"
    )

    # --- and no tutor role was granted ------------------------------------
    me = await client.get("/v1/auth/me", headers=bearer(tutor))
    assert "tutor" not in me.json()["roles"], "a refused claim granted the tutor role"


async def test_a_refused_claim_can_be_resubmitted_and_then_approved(
    committed_env: CommittedEnv,
) -> None:
    """The whole point of a reason: the tutor can act on it and be approved.

    Rejection is not a verdict on a person, so the loop has to close. A tutor who
    read the reason, supplied what was missing, and been refused again would have
    been told the process is arbitrary -- which is how a verification programme
    loses the people it exists to check.
    """
    client = committed_env.client
    course_unit = await first_course_unit(committed_env)
    poor_grade = await grade_named(client, "D")
    grade_a = await grade_named(client, "A")

    tutor = await register(client, "e2e.retried@student.mak.ac.ug")
    await complete_profile(client, tutor, course_unit=course_unit)
    admin = await grant_admin(committed_env, "e2e.retryadmin@peerpass.mak.ac.ug")

    first = await _submit(client, tutor, course_unit, poor_grade)
    await _review(
        client,
        admin,
        first["id"],
        status="rejected",
        rejection_reason="That result is below the bar for tutoring this unit.",
    )

    # --- the tutor supplies what was asked for -----------------------------
    resubmitted = await _submit(
        client,
        tutor,
        course_unit,
        grade_a,
        evidence="Corrected transcript, unit result page attached",
    )
    assert resubmitted["status"] == "pending", (
        f"a resubmission must return to pending, not stay refused: {resubmitted}"
    )
    # The reason is cleared: the tutor has replaced the thing it described.
    assert resubmitted["rejection_reason"] is None, (
        f"the tutor would still be told what was wrong with evidence they have "
        f"already replaced: {resubmitted}"
    )

    # --- and it is queued for a fresh decision ----------------------------
    row = await _row_for(client, admin, "e2e.retried@student.mak.ac.ug")
    assert row["status"] == "pending", row
    assert row["evidence_reference"] == (
        "Corrected transcript, unit result page attached"
    ), row
    assert row["meets_threshold"] is True, row

    await _review(client, admin, resubmitted["id"], status="verified")

    me = await client.get("/v1/auth/me", headers=bearer(tutor))
    assert "tutor" in me.json()["roles"], (
        f"the resubmitted claim was never approved: {me.json()['roles']}"
    )
