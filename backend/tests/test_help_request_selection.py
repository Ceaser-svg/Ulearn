"""The student chooses a tutor; that tutor confirms or declines.

MVP decision 3 says the tutee picks from a short list, and that the tutor then
answers. Two halves of that are asserted here, and the second is the one that is
easy to leave out.

The student may only choose from tutors the engine would propose. The service
re-derives the candidate list rather than trusting the id in the body, because a
request body is whatever the caller chose to send -- an id that once appeared in
a list the client holds proves nothing about the tutor's competency, grade or
standing at the moment of the request. Every refusal case below is built so the
tutor is *almost* eligible, which is what makes the gate the reason for the
answer rather than an accident of the fixture.

The tutor may only confirm the request that named them. A session could be
created by any tutor against any unselected request before this change, which set
`matched_tutor_id` to the caller and never asked the student -- the exact inverse
of the decision, and the one place a tutor could take work a student had refused
them.

The service tests call the services, because a rule reachable only through a
router is a rule nobody can read. The wire tests go through the real router with
real tokens, because the route ordering, the auth guard, and the status codes are
only observable there.
"""

from decimal import Decimal

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core.exceptions import (
    AuthorizationProblem,
    ConflictProblem,
    NotFoundProblem,
    ValidationProblem,
)
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Subject, University
from app.models.enums import (
    CompetencyStatus,
    HelpRequestStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade, GradingScale
from app.models.session import HelpRequest, Session
from app.models.tutor_profile import TutorProfile
from app.models.user import User, set_roles
from app.schemas.matching import MatchRequest
from app.schemas.session import HelpRequestCreate, SelectTutorRequest, SessionCreate
from app.services import matching_service, session_service
from tests.support import sole_faculty_id

GOOD_PASSWORD = "correct horse battery staple"


async def _campus(db_session, *, codes: tuple[str, ...] = ("CSC 121",)):
    """A university whose scale gates competency at B+, with a grade either side.

    `B+` sits at exactly `competency_min_points` and `B` below it, so the gate has
    an unambiguous in and an unambiguous out. A fixture offering only a grade that
    clears the bar would test the happy path and say nothing about where the bar
    is, which is the one thing a selection refusal needs to be about.
    """
    scale = GradingScale(
        name="Makerere 5-point",
        max_points=Decimal("5.00"),
        competency_min_points=Decimal("4.00"),
    )
    university = University(name="Makerere University", grading_scale=scale)
    subject = Subject(name="Computer Science")
    grades = {
        label: Grade(
            label=label,
            grade_points=Decimal(points),
            max_points=Decimal("5.00"),
            grading_scale=scale,
        )
        for label, points in (("A", "5.00"), ("B+", "4.00"), ("B", "3.50"))
    }
    units = {
        code: CourseUnit(
            code=code,
            name=f"Unit {code}",
            subject=subject,
            university=university,
            grade=grades["A"],
        )
        for code in codes
    }
    db_session.add_all([scale, university, subject, *grades.values(), *units.values()])
    await db_session.flush()
    return university, grades, units


async def _student(db_session, university, *, email: str = "student@mak.ac.ug") -> User:
    user = User(
        email=email,
        password_hash="hashed-password",
        full_name="Student Example",
        university=university,
        faculty_id=await sole_faculty_id(db_session, university),
    )
    db_session.add(user)
    await db_session.flush()
    return user


async def _tutor(
    db_session,
    *,
    university: University,
    units: list[CourseUnit],
    grade: Grade,
    email: str,
    standing: TutorStanding = TutorStanding.VERIFIED,
    status: CompetencyStatus = CompetencyStatus.VERIFIED,
    profile: bool = True,
) -> User:
    """A tutor: the role, a profile unless refused one, one competency per unit."""
    user = User(
        email=email,
        password_hash="hashed-password",
        full_name="Tutor Example",
        university=university,
        faculty_id=await sole_faculty_id(db_session, university),
    )
    db_session.add(user)
    if profile:
        db_session.add(
            TutorProfile(
                user=user,
                standing=standing,
                completed_sessions=6,
                rating_total=Decimal("36.00"),
                rating_count=10,
            )
        )
    for unit in units:
        db_session.add(
            Competency(
                user=user,
                course_unit=unit,
                grade=grade,
                status=status,
                source=VerificationSource.TRANSCRIPT,
            )
        )
    await db_session.flush()
    await set_roles(db_session, user.id, {UserRole.TUTOR})
    return user


async def _request(db_session, student: User, unit: CourseUnit, topic: str = "graphs"):
    created = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(course_unit_id=unit.public_id, topic=topic),
    )
    await db_session.commit()
    return created


def _select(request_id, tutor_public_id):
    return SelectTutorRequest(candidate_tutor_id=tutor_public_id)


# --- choosing a tutor --------------------------------------------------------


async def test_selecting_a_tutor_waits_on_that_tutor(db_session):
    """The happy path, stated so the state it leaves is unambiguous.

    `PENDING_CONFIRMATION` is a distinct state rather than a flag, because
    without it a selected tutor is indistinguishable from an unselected one and
    the tutor has no way to learn they were chosen.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])

    selected = await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, tutor.public_id)
    )

    assert selected.status is HelpRequestStatus.PENDING_CONFIRMATION
    assert selected.matched_tutor_id == tutor.public_id


async def test_a_student_cannot_choose_themselves(db_session):
    """Refused as itself, not as "not eligible".

    The search already excludes the caller, so this would be refused either way;
    what is asserted is *which* refusal. A student who also tutors deserves to be
    told they cannot be their own answer, and a bare "not eligible" for the one
    candidate they can see would read as the platform having no tutors at all.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university, email="both@mak.ac.ug")
    db_session.add(
        TutorProfile(
            user=student,
            standing=TutorStanding.VERIFIED,
            rating_total=Decimal("45.00"),
            rating_count=10,
        )
    )
    db_session.add(
        Competency(
            user=student,
            course_unit=units["CSC 121"],
            grade=grades["A"],
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    await db_session.flush()
    await set_roles(db_session, student.id, {UserRole.STUDENT, UserRole.TUTOR})
    request = await _request(db_session, student, units["CSC 121"])

    with pytest.raises(ValidationProblem, match="your own tutor"):
        await matching_service.select_tutor_for_request(
            db_session, student, request.id, _select(request.id, student.public_id)
        )


async def test_an_ineligible_tutor_is_refused_even_when_the_id_is_sent_directly(
    db_session,
):
    """The rule this endpoint exists to enforce.

    Every tutor here fails exactly one clause of the gate and is otherwise a
    perfect candidate, so a refusal is about the clause and not about a fixture
    that was never a candidate. Each is first shown to be absent from the
    proposals, which is what makes the second half of the test mean something: the
    service is not consulting the client's list, it is deriving the same answer.
    """
    university, grades, units = await _campus(db_session, codes=("CSC 121", "CSC 122"))
    student = await _student(db_session, university)

    # The wrong unit: a verified A in a sibling course is not a weaker candidate
    # for this one, it is no candidate.
    wrong_unit = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 122"]],
        grade=grades["A"],
        email="wrong-unit@mak.ac.ug",
    )
    below_bar = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B"],
        email="below-bar@mak.ac.ug",
    )
    unchecked = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        status=CompetencyStatus.PENDING,
        email="unchecked@mak.ac.ug",
    )
    suspended = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        standing=TutorStanding.SUSPENDED,
        email="suspended@mak.ac.ug",
    )
    profileless = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="profileless@mak.ac.ug",
        profile=False,
    )
    eligible = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B+"],
        email="eligible@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])

    proposals = await matching_service.match_tutors(
        db_session,
        student,
        MatchRequest(course_unit_id=units["CSC 121"].public_id),
    )
    proposed = {item.tutor.user_id for item in proposals.candidates}
    assert proposed == {eligible.public_id}

    for tutor in (wrong_unit, below_bar, unchecked, suspended, profileless):
        with pytest.raises(ValidationProblem, match="cannot be chosen"):
            await matching_service.select_tutor_for_request(
                db_session, student, request.id, _select(request.id, tutor.public_id)
            )

    # Nothing above changed the request: a refused selection leaves it open, so
    # the student can pick again rather than being locked out of their own request.
    row = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    assert row is not None
    assert row.status is HelpRequestStatus.OPEN
    assert row.matched_tutor_id is None


async def test_a_student_cannot_choose_for_someone_elses_request(db_session):
    """Ownership first, so a guessed id reveals nothing at all.

    Not a 403: "it exists but is not yours" is an answer, and the answer to that
    is the same one as for an id that was never issued.
    """
    university, grades, units = await _campus(db_session)
    owner = await _student(db_session, university, email="owner@mak.ac.ug")
    stranger = await _student(db_session, university, email="stranger@mak.ac.ug")
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="shared@mak.ac.ug",
    )
    request = await _request(db_session, owner, units["CSC 121"])

    with pytest.raises(NotFoundProblem):
        await matching_service.select_tutor_for_request(
            db_session, stranger, request.id, _select(request.id, tutor.public_id)
        )


async def test_a_tutor_cannot_be_chosen_twice(db_session):
    """The second tap is a conflict, and it leaves the first choice intact.

    A phone sends this twice routinely -- a double tap, a retry on a slow network
    -- so the answer is "that has already changed", not a silent reassignment.
    Silently accepting it would move the request onto a second tutor the student
    never chose, and the first tutor would still be holding a pending decision
    nobody meant to give them.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    chosen = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="first@mak.ac.ug",
    )
    other = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="second@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, chosen.public_id)
    )

    with pytest.raises(ConflictProblem):
        await matching_service.select_tutor_for_request(
            db_session, student, request.id, _select(request.id, other.public_id)
        )

    row = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    assert row is not None
    assert row.matched_tutor_id == chosen.id


# --- the tutor answers -------------------------------------------------------


async def test_the_chosen_tutor_sees_the_request_waiting_on_them(db_session):
    """A tutor who was not chosen sees nothing.

    Scoped by the query rather than by a role check, so the screen is empty rather
    than a permission error for anyone who cannot have been named.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    chosen = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    bystander = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="bystander@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, chosen.public_id)
    )

    awaiting = await matching_service.list_requests_awaiting_confirmation(
        db_session, chosen
    )

    assert [row.id for row in awaiting] == [request.id]
    assert (
        await matching_service.list_requests_awaiting_confirmation(
            db_session, bystander
        )
        == []
    )


async def test_the_chosen_tutor_may_decline(db_session):
    """`DECLINED` is recorded, and the tutor's list empties.

    Declining has to be visible afterwards, or a request the tutor refused is
    indistinguishable from one nobody was ever asked -- which is the exact
    difference the state exists to express.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, tutor.public_id)
    )

    declined = await matching_service.decline_help_request(
        db_session, tutor, request.id
    )

    assert declined.status is HelpRequestStatus.DECLINED
    # The tutor who was named is retained: the record of who said no is the point.
    assert declined.matched_tutor_id == tutor.public_id
    assert (
        await matching_service.list_requests_awaiting_confirmation(db_session, tutor)
        == []
    )


@pytest.mark.parametrize("actor", ["student", "other_tutor"])
async def test_only_the_chosen_tutor_may_decline(db_session, actor):
    """A 404 rather than a 403, for the reason ownership always is.

    The student who made the request cannot decline it from the other end of the
    platform, and neither can a tutor who was not chosen; both are the same
    "not yours" as an id that was never issued.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    other = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="other@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, tutor.public_id)
    )

    with pytest.raises(NotFoundProblem):
        await matching_service.decline_help_request(
            db_session, student if actor == "student" else other, request.id
        )


async def test_a_declined_request_cannot_be_confirmed(db_session):
    """A refusal is final.

    Re-opening it would let a tutor decline and then watch the student re-select
    them, and would make `DECLINED` a pause rather than an answer. The recovery is
    a new request, which keeps the record of what was asked intact.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, tutor.public_id)
    )
    await matching_service.decline_help_request(db_session, tutor, request.id)

    with pytest.raises(ConflictProblem):
        await session_service.create_session(
            db_session,
            tutor,
            SessionCreate(
                help_request_id=request.id,
                course_unit_id=units["CSC 121"].public_id,
                topic="graphs",
                duration_minutes=60,
            ),
        )


# --- the tutor confirms ------------------------------------------------------


async def _pending(db_session, *, student=None, tutor_email="chosen@mak.ac.ug"):
    """A campus with one request waiting on one tutor, for the confirm cases."""
    university, grades, units = await _campus(db_session)
    owner = student or await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email=tutor_email,
    )
    request = await _request(db_session, owner, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, owner, request.id, _select(request.id, tutor.public_id)
    )
    return owner, tutor, request, units["CSC 121"]


def _session_for(request, unit, *, topic="graphs"):
    return SessionCreate(
        help_request_id=request.id,
        course_unit_id=unit.public_id,
        topic=topic,
        duration_minutes=60,
    )


async def test_the_chosen_tutor_confirms_and_the_request_is_matched(db_session):
    """The whole loop, from the tutor's side of it."""
    _student_user, tutor, request, unit = await _pending(db_session)

    created = await session_service.create_session(
        db_session, tutor, _session_for(request, unit)
    )

    assert created.help_request_id == request.id
    assert created.tutor_id == tutor.public_id
    row = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    assert row is not None and row.status is HelpRequestStatus.MATCHED


async def test_a_tutor_who_was_not_chosen_cannot_confirm(db_session):
    """The self-claim path, gone.

    `create_session` used to accept any tutor against an unselected request: if
    `matched_tutor_id` was null it set it to the caller and marked the request
    matched, so any tutor could take any student's open request without the
    student ever being asked. This tutor is fully eligible -- same university,
    verified A in the unit, verified standing -- and is still refused, because
    eligibility is not consent.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    chosen = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    opportunist = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="opportunist@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    await matching_service.select_tutor_for_request(
        db_session, student, request.id, _select(request.id, chosen.public_id)
    )

    with pytest.raises(AuthorizationProblem, match="the student chose"):
        await session_service.create_session(
            db_session, opportunist, _session_for(request, units["CSC 121"])
        )


async def test_a_tutor_cannot_claim_a_request_nobody_selected(db_session):
    """The open request is not claimable at all.

    The stronger form of the case above, and the one the old code got wrong
    outright: an `OPEN` request has no `matched_tutor_id`, and the removed branch
    filled it in. Nothing now can.
    """
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="opportunist@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])

    with pytest.raises(AuthorizationProblem, match="the student chose"):
        await session_service.create_session(
            db_session, tutor, _session_for(request, units["CSC 121"])
        )

    row = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    assert row is not None
    assert row.matched_tutor_id is None
    assert row.status is HelpRequestStatus.OPEN


async def test_confirming_a_request_that_was_never_selected_is_refused(db_session):
    """`OPEN` is not `PENDING_CONFIRMATION`, and the difference is enforced."""
    university, grades, units = await _campus(db_session)
    student = await _student(db_session, university)
    tutor = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["A"],
        email="chosen@mak.ac.ug",
    )
    request = await _request(db_session, student, units["CSC 121"])
    # The tutor is written in without the status, which is the state the student
    # choosing them establishes. A row like this is reachable only by writing
    # around the service, and the service has to have an answer for it anyway.
    row = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    assert row is not None
    row.matched_tutor_id = tutor.id
    await db_session.commit()

    with pytest.raises(ConflictProblem):
        await session_service.create_session(
            db_session, tutor, _session_for(request, units["CSC 121"])
        )


async def test_confirming_an_already_matched_request_is_refused(db_session):
    """A retried accept must not hand the student a second session.

    A phone sends this twice routinely, so the second one is a conflict rather
    than an error, and the first session is untouched.
    """
    _student_user, tutor, request, unit = await _pending(db_session)
    created = await session_service.create_session(
        db_session, tutor, _session_for(request, unit)
    )

    with pytest.raises(ConflictProblem):
        await session_service.create_session(
            db_session, tutor, _session_for(request, unit)
        )

    rows = (
        (
            await db_session.execute(
                select(Session).where(Session.public_id == created.id)
            )
        )
        .scalars()
        .all()
    )
    assert len(rows) == 1


async def test_one_session_per_help_request_is_enforced_by_the_service(db_session):
    """The service-level half of `session_per_request`.

    The status is put back to `PENDING_CONFIRMATION` by hand to reach the branch:
    with the status check in place, a second confirm is refused earlier, and a
    test that only ever hit that refusal would say nothing about the one-session
    guarantee. The constraint itself is what settles a race between two
    simultaneous requests, so both are asserted.
    """
    _student_user, tutor, request, unit = await _pending(db_session)
    await session_service.create_session(db_session, tutor, _session_for(request, unit))
    row = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    assert row is not None
    row.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()

    with pytest.raises(ConflictProblem, match="already has an accepted session"):
        await session_service.create_session(
            db_session, tutor, _session_for(request, unit)
        )


async def test_the_database_refuses_a_second_session_for_one_request(db_session):
    """`session_per_request`, asserted where it actually lives.

    A service check is a read followed by a write, so two simultaneous confirms
    both pass it. The unique constraint is what makes the guarantee real, and a
    test that only exercised the service would pass with the constraint dropped.
    """
    _student_user, tutor, request, unit = await _pending(db_session)
    created = await session_service.create_session(
        db_session, tutor, _session_for(request, unit)
    )

    existing = await db_session.scalar(
        select(Session).where(Session.public_id == created.id)
    )
    assert existing is not None
    db_session.add(
        Session(
            help_request_id=existing.help_request_id,
            tutee_id=existing.tutee_id,
            tutor_id=existing.tutor_id,
            course_unit_id=existing.course_unit_id,
            topic="graphs",
            duration_minutes=30,
        )
    )

    with pytest.raises(IntegrityError):
        await db_session.commit()
    # The failed statement poisons the transaction on PostgreSQL, and a later
    # assertion in the same test would fail for that reason rather than its own.
    await db_session.rollback()


# --- the wire ----------------------------------------------------------------
#
# The cases above call the services, which is the only way to read a rule. These
# go through the real router with real tokens, which is the only way to see the
# things the service cannot tell you: that the URL exists, that the auth guard is
# on it, that `/help-requests/awaiting-me` is reachable rather than swallowed by
# `/help-requests/{request_id}`, and that a refusal reaches a phone as a status
# code rather than as an exception.


async def _account(client, db_session, email: str, university: University) -> dict:
    """A registered account with a live token, and the university set directly.

    `PATCH /v1/users/me` has its own tests; these cases are about the choice, not
    about how a student gets a university onto their account.
    """
    response = await client.post(
        "/v1/auth/register", json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 201, response.text
    user = await db_session.scalar(select(User).where(User.email == email))
    assert user is not None
    user.university_id = university.id
    user.faculty_id = await sole_faculty_id(db_session, university)
    await db_session.commit()
    return response.json()


def _bearer(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['tokens']['access_token']}"}


async def _wire_tutor(
    client,
    db_session,
    email: str,
    university: University,
    unit: CourseUnit,
    grade: Grade,
) -> dict:
    """A registered tutor with a token and the standing the engine would accept.

    Registered first, then qualified in place, so the account the request goes out
    as is the same row that holds the role. Building the tutor directly and
    registering a second account with a similar email gives two users, and the
    second one has no tutor role -- which is a different refusal entirely.
    """
    body = await _account(client, db_session, email, university)
    user = await db_session.scalar(select(User).where(User.email == email))
    assert user is not None
    db_session.add(
        TutorProfile(
            user=user,
            standing=TutorStanding.VERIFIED,
            rating_total=Decimal("30.00"),
            rating_count=8,
        )
    )
    db_session.add(
        Competency(
            user=user,
            course_unit=unit,
            grade=grade,
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    await db_session.flush()
    await set_roles(db_session, user.id, {UserRole.TUTOR})
    return body


async def _flow(client, db_session, *, tutor_email="wire-tutor@mak.ac.ug"):
    """A student, a tutor, and a request the student has chosen that tutor on.

    Returns the campus alongside the flow, because a second call to `_campus` in
    the same test would collide with the unique `subjects.name`.
    """
    university, grades, units = await _campus(db_session)
    student = await _account(client, db_session, "wire-student@mak.ac.ug", university)
    tutor_body = await _wire_tutor(
        client, db_session, tutor_email, university, units["CSC 121"], grades["A"]
    )
    tutor = await db_session.scalar(select(User).where(User.email == tutor_email))
    assert tutor is not None

    created = await client.post(
        "/v1/matching/help-requests",
        headers=_bearer(student),
        json={"course_unit_id": str(units["CSC 121"].public_id), "topic": "graphs"},
    )
    assert created.status_code == 201, created.text
    request = created.json()

    selected = await client.post(
        f"/v1/matching/help-requests/{request['id']}/select",
        headers=_bearer(student),
        json={"candidate_tutor_id": str(tutor.public_id)},
    )
    assert selected.status_code == 200, selected.text
    assert selected.json()["status"] == "pending_confirmation"
    assert selected.json()["matched_tutor_id"] == str(tutor.public_id)
    return student, tutor_body, tutor, request, (university, grades, units["CSC 121"])


async def test_the_chosen_tutor_can_decline_over_the_wire(client, db_session):
    """The student is told, by name, that the tutor they chose turned it down."""
    student, tutor_body, _tutor_user, request, _unit = await _flow(client, db_session)

    awaiting = await client.get(
        "/v1/matching/help-requests/awaiting-me", headers=_bearer(tutor_body)
    )
    assert awaiting.status_code == 200, awaiting.text
    assert [row["id"] for row in awaiting.json()] == [request["id"]]

    declined = await client.post(
        f"/v1/matching/help-requests/{request['id']}/decline",
        headers=_bearer(tutor_body),
    )
    assert declined.status_code == 200, declined.text
    assert declined.json()["status"] == "declined"

    mine = await client.get("/v1/matching/help-requests/me", headers=_bearer(student))
    assert mine.status_code == 200, mine.text
    assert mine.json()[0]["status"] == "declined"


async def test_the_chosen_tutor_can_confirm_over_the_wire(client, db_session):
    """The loop closes: a student asks, a tutor is chosen, the tutor confirms."""
    _student_body, tutor_body, _tutor_user, request, (_u, _g, unit) = await _flow(
        client, db_session
    )

    created = await client.post(
        "/v1/sessions",
        headers=_bearer(tutor_body),
        json={
            "help_request_id": request["id"],
            "course_unit_id": str(unit.public_id),
            "topic": "graphs",
            "duration_minutes": 60,
        },
    )

    assert created.status_code == 201, created.text
    # Nothing is left waiting on the tutor once the session exists.
    awaiting = await client.get(
        "/v1/matching/help-requests/awaiting-me", headers=_bearer(tutor_body)
    )
    assert awaiting.json() == []


async def test_a_tutor_who_was_not_chosen_is_refused_over_the_wire(client, db_session):
    """A fully eligible tutor, a real session body, and a 403.

    Same university, verified A in the unit, verified standing, and a body whose
    every field is correct -- which is what makes this the case that matters.
    Nothing in a session payload says who was chosen; only `matched_tutor_id`
    does. The tutor is refused for having been passed over, not for being
    unqualified, and a test built from a weaker tutor could not tell those apart.
    """
    (
        _student_body,
        _tutor_body,
        _chosen,
        request,
        (university, grades, unit),
    ) = await _flow(client, db_session)
    opportunist = await _wire_tutor(
        client,
        db_session,
        "opportunist@mak.ac.ug",
        university,
        unit,
        grades["A"],
    )

    response = await client.post(
        "/v1/sessions",
        headers=_bearer(opportunist),
        json={
            "help_request_id": request["id"],
            "course_unit_id": str(unit.public_id),
            "topic": "graphs",
            "duration_minutes": 60,
        },
    )

    assert response.status_code == 403, response.text
    assert "student chose" in response.json()["detail"]


async def test_selecting_without_a_token_is_refused(client, db_session):
    """The auth guard is on the endpoint, not only on the service.

    The request body is deliberately a real course unit's id rather than a
    nonsense one: an unauthenticated caller is turned away before anything is
    looked up, so the answer must not depend on the body resolving.
    """
    university, _grades, units = await _campus(db_session)
    student = await _account(client, db_session, "anon@mak.ac.ug", university)
    created = await client.post(
        "/v1/matching/help-requests",
        headers=_bearer(student),
        json={"course_unit_id": str(units["CSC 121"].public_id), "topic": "graphs"},
    )
    assert created.status_code == 201, created.text

    response = await client.post(
        f"/v1/matching/help-requests/{created.json()['id']}/select",
        json={"candidate_tutor_id": str(units["CSC 121"].public_id)},
    )

    assert response.status_code == 401, response.text


async def test_selecting_an_ineligible_tutor_is_a_422_over_the_wire(client, db_session):
    """A body the engine would not have proposed is refused with a field error.

    The error is on `candidate_tutor_id`, which is the field the client sent and
    can correct -- not on the request, which was well formed.

    The tutor is refused on a grade, not on the course unit. A sibling course in
    the same subject is *not* a usable example here: when a unit has no exact
    candidates the engine widens to the subject, so a tutor competent in `CSC 122`
    is a genuine candidate for a `CSC 121` request with nobody else available, and
    the client was shown them for that reason. Refusing them would mean the
    endpoint was stricter than the list the student chose from.
    """
    university, grades, units = await _campus(db_session)
    student = await _account(client, db_session, "wire-refused@mak.ac.ug", university)
    below_bar = await _tutor(
        db_session,
        university=university,
        units=[units["CSC 121"]],
        grade=grades["B"],
        email="wire-below-bar@mak.ac.ug",
    )
    created = await client.post(
        "/v1/matching/help-requests",
        headers=_bearer(student),
        json={"course_unit_id": str(units["CSC 121"].public_id), "topic": "graphs"},
    )

    response = await client.post(
        f"/v1/matching/help-requests/{created.json()['id']}/select",
        headers=_bearer(student),
        json={"candidate_tutor_id": str(below_bar.public_id)},
    )

    assert response.status_code == 422, response.text
    assert "candidate_tutor_id" in response.json()["errors"]


async def test_confirming_twice_is_a_409_over_the_wire(client, db_session):
    """The retry a phone sends anyway, answered as a conflict."""
    _student_body, tutor_body, _tutor_user, request, (_u, _g, unit) = await _flow(
        client, db_session
    )
    body = {
        "help_request_id": request["id"],
        "course_unit_id": str(unit.public_id),
        "topic": "graphs",
        "duration_minutes": 60,
    }
    first = await client.post("/v1/sessions", headers=_bearer(tutor_body), json=body)
    assert first.status_code == 201, first.text

    second = await client.post("/v1/sessions", headers=_bearer(tutor_body), json=body)

    assert second.status_code == 409, second.text


async def test_awaiting_me_does_not_shadow_the_request_by_id_route(client, db_session):
    """Two literal segments, one parameterised route, and the order they are in.

    FastAPI matches in declaration order, so a literal path declared after
    `/help-requests/{request_id}` is unreachable -- it is read as a UUID and comes
    back as a 422 for a path that does exist. Asserted over the route table as well
    as over a request, because a route that is registered but shadowed fails only
    one of the two.
    """
    from app.main import create_app

    paths = create_app().openapi()["paths"]

    assert "/v1/matching/help-requests/awaiting-me" in paths
    assert "/v1/matching/help-requests/{request_id}/select" in paths
    assert "/v1/matching/help-requests/{request_id}/decline" in paths
