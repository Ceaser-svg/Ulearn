"""What an operator needs in order to triage the competency review queue.

The queue is the console's one screen where an operator makes a decision that
changes somebody's access to work, and each field here exists because its absence
made that decision worse:

* the grade *label*, because `4.30` is not the thing a marker recognises,
* the bar the grade has to clear and whether it clears it, because the server
  refuses to verify below the bar and an operator who cannot see the bar learns
  that only by being refused,
* the rejection reason, because a tutor who is told no without a reason cannot
  act on it, and
* a filter, because the queue is worked one status at a time.

The threshold comparison is asserted against the seeded scale rather than against
a literal, because a literal here would pass while the console and the verifier
disagreed about which bar they were using -- the failure this is here to catch.
"""

from httpx import AsyncClient
from sqlalchemy import select

from app.models.course_unit import University
from app.models.grading_scale import GradingScale
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
) -> dict:
    response = await client.post(
        "/v1/competencies",
        headers=bearer(account),
        json={
            "course_unit_id": course_unit["id"],
            "grade_id": grade["id"],
            "source": "transcript",
            "evidence_reference": "Semester 5 transcript",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def _queue(client: AsyncClient, admin: dict, **params: str) -> dict:
    response = await client.get(
        "/v1/admin/competencies",
        params=params,
        headers=bearer(admin),
    )
    assert response.status_code == 200, response.text
    return response.json()


async def _scale_min_points(env: CommittedEnv) -> str:
    """The bar the verifier enforces, read from the seed.

    Read from the database rather than hardcoded so that these tests fail if the
    console's number and the server's number ever diverge -- which is the bug the
    whole threshold column exists to prevent.
    """
    async with env.session() as session:
        scale = await session.scalar(select(GradingScale).limit(1))
        assert scale is not None, "the suite needs a seeded grading scale"
        return str(scale.competency_min_points)


async def test_the_queue_shows_the_label_the_bar_and_whether_the_grade_clears_it(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    tutor = await register(committed_client, "queue-label@student.must.ac.ug")
    await complete_profile(committed_client, tutor, course_unit=unit)
    await _submit(
        committed_client, tutor, unit, await grade_named(committed_client, "A")
    )
    admin = await grant_admin(committed_env, "queue-label-admin@must.ac.ug")

    minimum = await _scale_min_points(committed_env)
    row = (await _queue(committed_client, admin))["items"][0]

    # The label, because a marker reads "A", not "4.30".
    assert row["grade_label"] == "A"
    # The bar and the verdict, so the operator is not discovering the gate by
    # being refused.
    assert row["competency_min_points"] == minimum
    assert row["meets_threshold"] is True


async def test_a_grade_under_the_bar_is_reported_as_not_clearing_it(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    tutor = await register(committed_client, "queue-low@student.must.ac.ug")
    await complete_profile(committed_client, tutor, course_unit=unit)
    # Seeded below the bar: the submission itself must still be accepted, since
    # the gate applies at review, not at submission.
    await _submit(
        committed_client, tutor, unit, await grade_named(committed_client, "D")
    )
    admin = await grant_admin(committed_env, "queue-low-admin@must.ac.ug")

    row = (await _queue(committed_client, admin))["items"][0]

    assert row["grade_label"] == "D"
    assert row["meets_threshold"] is False


async def test_the_queue_can_be_narrowed_to_one_status(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    grade = await grade_named(committed_client, "A")
    pending = await register(committed_client, "queue-pending@student.must.ac.ug")
    await complete_profile(committed_client, pending, course_unit=unit)
    decided = await register(committed_client, "queue-decided@student.must.ac.ug")
    await complete_profile(committed_client, decided, course_unit=unit)

    waiting = await _submit(committed_client, pending, unit, grade)
    refused = await _submit(committed_client, decided, unit, grade)
    admin = await grant_admin(committed_env, "queue-filter-admin@must.ac.ug")
    review = await committed_client.patch(
        f"/v1/admin/competencies/{refused['id']}/review",
        headers=bearer(admin),
        json={
            "status": "rejected",
            "rejection_reason": "The transcript does not show CS301.",
        },
    )
    assert review.status_code == 200, review.text

    # Omitting the filter is every status, which is what the console opens on.
    everything = await _queue(committed_client, admin)
    assert everything["total"] == 2

    only_pending = await _queue(committed_client, admin, status="pending")
    assert [row["id"] for row in only_pending["items"]] == [waiting["id"]]
    # `total` counts the match, not the page, so the pager is honest.
    assert only_pending["total"] == 1

    only_rejected = await _queue(committed_client, admin, status="rejected")
    assert [row["id"] for row in only_rejected["items"]] == [refused["id"]]

    # A filter that matches nothing is an empty page, not an error: an operator
    # who has just worked the pending queue to empty has not done anything wrong.
    empty = await _queue(committed_client, admin, status="verified")
    assert empty == {
        "items": [],
        "total": 0,
        "limit": empty["limit"],
        "offset": 0,
        "has_more": False,
        "page_count": 0,
    }


async def test_the_queue_refuses_a_filter_it_cannot_understand(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    admin = await grant_admin(committed_env, "queue-badfilter-admin@must.ac.ug")

    response = await committed_client.get(
        "/v1/admin/competencies",
        params={"status": "approved"},
        headers=bearer(admin),
    )

    # 422 rather than an empty page: a filter that silently matches nothing looks
    # identical to a queue that is genuinely empty, and an operator working a
    # live review queue cannot afford to be wrong in that direction.
    assert response.status_code == 422, response.text


async def test_the_queue_shows_the_reason_a_submission_was_refused(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    unit = await first_course_unit(committed_env)
    tutor = await register(committed_client, "queue-reason@student.must.ac.ug")
    await complete_profile(committed_client, tutor, course_unit=unit)
    submitted = await _submit(
        committed_client, tutor, unit, await grade_named(committed_client, "A")
    )
    admin = await grant_admin(committed_env, "queue-reason-admin@must.ac.ug")
    await committed_client.patch(
        f"/v1/admin/competencies/{submitted['id']}/review",
        headers=bearer(admin),
        json={
            "status": "rejected",
            "rejection_reason": "The transcript page is missing.",
        },
    )

    row = (await _queue(committed_client, admin, status="rejected"))["items"][0]

    assert row["rejection_reason"] == "The transcript page is missing."


async def test_an_audit_row_names_the_operator_who_acted(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    admin = await grant_admin(committed_env, "audit-actor@must.ac.ug")
    await _queue(committed_client, admin)

    response = await committed_client.get(
        "/v1/admin/audit-events", headers=bearer(admin)
    )

    assert response.status_code == 200, response.text
    row = response.json()["items"][0]
    # A log row that shows a bare UUID cannot answer "who did this", which is the
    # only question an audit log exists to answer.
    assert row["actor_email"] == "audit-actor@must.ac.ug"
    # And the identifier is still there, so an auditor can join on it.
    assert row["actor_id"]


async def test_an_audit_row_falls_back_to_the_email_when_there_is_no_name(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    admin = await grant_admin(committed_env, "audit-noname@must.ac.ug")
    await _queue(committed_client, admin)

    response = await committed_client.get(
        "/v1/admin/audit-events", headers=bearer(admin)
    )

    assert response.status_code == 200, response.text
    row = response.json()["items"][0]
    # `grant_admin` registers without a full name, which is a real state for a
    # staff account created in a hurry.
    assert row["actor_name"] is None
    assert row["actor_email"] == "audit-noname@must.ac.ug"


async def test_a_filtered_queue_read_is_audited_with_the_filter(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    admin = await grant_admin(committed_env, "audit-filter@must.ac.ug")

    await _queue(committed_client, admin, status="pending")

    response = await committed_client.get(
        "/v1/admin/audit-events", headers=bearer(admin)
    )
    row = response.json()["items"][0]
    # A filtered read is a different read, and "what was pending on Tuesday" is
    # unanswerable if the log does not record that the operator narrowed it.
    assert row["action"] == "admin.competencies.list"
    assert row["context"]["status"] == "pending"


async def test_the_threshold_is_reported_against_the_units_own_scale(
    committed_client: AsyncClient, committed_env: CommittedEnv
) -> None:
    """The bar travels with the university, not with the console.

    The gate is read from the course unit's university's grading scale, so two
    universities can hold different bars and the console must show each unit's
    own. A single hardcoded bar in the client would be the bug this forbids.
    """
    unit = await first_course_unit(committed_env)
    tutor = await register(committed_client, "queue-ownscale@student.must.ac.ug")
    await complete_profile(committed_client, tutor, course_unit=unit)
    await _submit(
        committed_client, tutor, unit, await grade_named(committed_client, "A")
    )
    admin = await grant_admin(committed_env, "queue-ownscale-admin@must.ac.ug")

    row = (await _queue(committed_client, admin))["items"][0]

    async with committed_env.session() as session:
        university = await session.scalar(
            select(University)
            .join(University.grading_scale)
            .where(University.grading_scale_id.is_not(None))
        )
        assert university is not None
        scale = await session.scalar(
            select(GradingScale).where(GradingScale.id == university.grading_scale_id)
        )
        assert scale is not None
        assert row["competency_min_points"] == str(scale.competency_min_points)
