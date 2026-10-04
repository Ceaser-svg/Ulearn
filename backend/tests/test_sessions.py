"""Session lifecycle tests."""

from decimal import Decimal

import pytest
from sqlalchemy import select, update

from app.core.exceptions import ValidationProblem
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Subject, University
from app.models.enums import (
    CompetencyStatus,
    HelpRequestStatus,
    SessionStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade, GradingScale
from app.models.session import HelpRequest, Session
from app.models.tutor_profile import TutorProfile
from app.models.user import User, set_roles
from app.schemas.session import (
    HelpRequestCreate,
    SessionCreate,
    SessionTransitionRequest,
)
from app.services import matching_service, session_service


async def _seed_session_data(db_session):
    scale = GradingScale(
        name="Makerere 5-point",
        max_points=Decimal("5.00"),
        competency_min_points=Decimal("4.00"),
    )
    university = University(name="Makerere University", grading_scale=scale)
    subject = Subject(name="Computer Science")
    grade = Grade(
        label="A",
        grade_points=Decimal("4.50"),
        max_points=Decimal("5.00"),
        grading_scale=scale,
    )
    course_unit = CourseUnit(
        code="CSC 121",
        name="Algorithms",
        subject=subject,
        university=university,
        grade=grade,
    )
    student = User(
        email="student@mak.ac.ug",
        password_hash="hashed-password",
        full_name="Student Example",
        university=university,
        faculty=subject,
    )
    tutor = User(
        email="tutor@mak.ac.ug",
        password_hash="hashed-password",
        full_name="Tutor Example",
        university=university,
        faculty=subject,
    )
    tutor_profile = TutorProfile(
        user=tutor,
        standing=TutorStanding.VERIFIED,
        completed_sessions=12,
        rating_total=Decimal("42.00"),
        rating_count=10,
    )
    competency = Competency(
        user=tutor,
        course_unit=course_unit,
        grade=grade,
        status=CompetencyStatus.VERIFIED,
        source=VerificationSource.TRANSCRIPT,
    )
    db_session.add_all(
        [
            scale,
            university,
            subject,
            grade,
            course_unit,
            student,
            tutor,
            tutor_profile,
            competency,
        ]
    )
    await db_session.flush()
    await set_roles(db_session, tutor.id, {UserRole.TUTOR})
    await db_session.commit()
    return student, tutor, course_unit


async def _stored_pin(db_session, public_id) -> str:
    """The PIN as stored, for tests that need to act the handshake out.

    `create_session` returns a `SessionResponse`, and the PIN is no longer on it:
    it was readable by both parties, so the tutee could read their own and start
    the session alone. Reaching for the row keeps these tests on the side of the
    handshake that is allowed to know it, and makes that the only way to learn it.
    """
    row = await db_session.scalar(select(Session).where(Session.public_id == public_id))
    assert row is not None and row.session_pin is not None
    return row.session_pin


async def _start_session(db_session, session, student, pin=None):
    """Begin a session the way a client now must: the tutee enters the PIN."""
    return await session_service.verify_session_pin(
        db_session,
        student,
        session.id,
        pin if pin is not None else await _stored_pin(db_session, session.id),
    )


async def test_create_session_from_help_request_and_generate_pin(db_session):
    student, tutor, course_unit = await _seed_session_data(db_session)
    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(
            course_unit_id=course_unit.public_id,
            topic="quick sort",
            description="Need help with partitioning.",
        ),
    )
    help_request = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    help_request.matched_tutor_id = tutor.id
    # `PENDING_CONFIRMATION`, not `MATCHED`: that is the state the student choosing
    # this tutor establishes, and `create_session` is what moves it to `MATCHED`.
    # The tests below are about PINs and the session clock, so they start from the
    # state a chosen request is actually in rather than from the one the
    # confirmation produces. Who may confirm is asserted in
    # `test_help_request_selection.py`.
    help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()

    session = await session_service.create_session(
        db_session,
        tutor,
        SessionCreate(
            help_request_id=request.id,
            course_unit_id=course_unit.public_id,
            topic="quick sort",
            duration_minutes=60,
            meeting_link="https://meet.google.com/demo",
        ),
    )

    assert session.tutee_id == student.public_id
    assert session.tutor_id == tutor.public_id
    assert session.status is SessionStatus.SCHEDULED
    # Issued, but not on the response: see `_stored_pin`.
    assert len(await _stored_pin(db_session, session.id)) == 2
    assert session.meeting_link == "https://meet.google.com/demo"

    refreshed = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.id == help_request.id)
    )
    assert refreshed is not None and refreshed.status is HelpRequestStatus.MATCHED


async def test_starting_a_session_requires_the_correct_pin(db_session):
    student, tutor, course_unit = await _seed_session_data(db_session)
    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(
            course_unit_id=course_unit.public_id,
            topic="hash tables",
        ),
    )
    help_request = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    help_request.matched_tutor_id = tutor.id
    # `PENDING_CONFIRMATION`, not `MATCHED`: that is the state the student choosing
    # this tutor establishes, and `create_session` is what moves it to `MATCHED`.
    # The tests below are about PINs and the session clock, so they start from the
    # state a chosen request is actually in rather than from the one the
    # confirmation produces. Who may confirm is asserted in
    # `test_help_request_selection.py`.
    help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()
    created = await session_service.create_session(
        db_session,
        tutor,
        SessionCreate(
            help_request_id=request.id,
            course_unit_id=course_unit.public_id,
            topic="hash tables",
            duration_minutes=90,
        ),
    )

    # A pin generated by `Session.generate_session_pin` is two digits in the
    # range 00-99. Any two candidates are wrong only 98 times in 100, and a
    # single conditional is still wrong whenever the draw lands on it, so search
    # the space for a value the session cannot be using instead of guessing.
    stored = await _stored_pin(db_session, created.id)
    wrong_pin = next(
        candidate
        for candidate in (f"{n:02d}" for n in range(100))
        if candidate != stored
    )

    # The tutee enters it, so the wrong candidate is offered by `student`.
    with pytest.raises(ValidationProblem, match="PIN"):
        await session_service.verify_session_pin(
            db_session, student, created.id, wrong_pin
        )

    started = await _start_session(db_session, created, student)

    assert started.status is SessionStatus.IN_PROGRESS
    assert started.started_at is not None


async def test_a_session_without_a_stored_pin_rejects_every_candidate(db_session):
    """A missing stored pin must reject every candidate, blank included.

    Comparing the stripped input against `session.session_pin or ""` makes a
    whitespace-only pin compare equal to the empty expected value, which would
    start a session whose handshake was never satisfied.
    """
    student, tutor, course_unit = await _seed_session_data(db_session)
    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(course_unit_id=course_unit.public_id, topic="graphs"),
    )
    help_request = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    help_request.matched_tutor_id = tutor.id
    # `PENDING_CONFIRMATION`, not `MATCHED`: that is the state the student choosing
    # this tutor establishes, and `create_session` is what moves it to `MATCHED`.
    # The tests below are about PINs and the session clock, so they start from the
    # state a chosen request is actually in rather than from the one the
    # confirmation produces. Who may confirm is asserted in
    # `test_help_request_selection.py`.
    help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()
    created = await session_service.create_session(
        db_session,
        tutor,
        SessionCreate(
            help_request_id=request.id,
            course_unit_id=course_unit.public_id,
            topic="graphs",
            duration_minutes=60,
        ),
    )

    # Null the pin in the database rather than on the instance: `create_session`
    # returns a built `SessionResponse`, not a model, and the schema is frozen,
    # so there is no attribute to assign. The update filters on the public id
    # because that is the only id the response carries.
    await db_session.execute(
        update(Session).where(Session.public_id == created.id).values(session_pin=None)
    )
    await db_session.commit()

    # `VerifyPinRequest.pin` is bounded and trimmed by the schema at the route, so
    # a blank pin is refused before it arrives. The path that still has to fail
    # closed is the service, which is called directly here.
    for candidate in ("", "  ", "  \t ", "42"):
        with pytest.raises(ValidationProblem, match="PIN"):
            await session_service.verify_session_pin(
                db_session, student, created.id, candidate
            )


async def test_the_correct_pin_is_accepted_despite_surrounding_whitespace(db_session):
    """A tutor typing a pin into a field that pads it still starts the session."""
    student, tutor, course_unit = await _seed_session_data(db_session)
    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(course_unit_id=course_unit.public_id, topic="recursion"),
    )
    help_request = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    help_request.matched_tutor_id = tutor.id
    # `PENDING_CONFIRMATION`, not `MATCHED`: that is the state the student choosing
    # this tutor establishes, and `create_session` is what moves it to `MATCHED`.
    # The tests below are about PINs and the session clock, so they start from the
    # state a chosen request is actually in rather than from the one the
    # confirmation produces. Who may confirm is asserted in
    # `test_help_request_selection.py`.
    help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()
    created = await session_service.create_session(
        db_session,
        tutor,
        SessionCreate(
            help_request_id=request.id,
            course_unit_id=course_unit.public_id,
            topic="recursion",
            duration_minutes=60,
        ),
    )

    started = await session_service.verify_session_pin(
        db_session,
        student,
        created.id,
        f"  {await _stored_pin(db_session, created.id)}  ",
    )

    assert started.status is SessionStatus.IN_PROGRESS
    assert started.started_at is not None


async def test_marking_a_session_complete_stops_the_clock(db_session):
    student, tutor, course_unit = await _seed_session_data(db_session)
    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(
            course_unit_id=course_unit.public_id,
            topic="sorting",
        ),
    )
    help_request = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    help_request.matched_tutor_id = tutor.id
    # `PENDING_CONFIRMATION`, not `MATCHED`: that is the state the student choosing
    # this tutor establishes, and `create_session` is what moves it to `MATCHED`.
    # The tests below are about PINs and the session clock, so they start from the
    # state a chosen request is actually in rather than from the one the
    # confirmation produces. Who may confirm is asserted in
    # `test_help_request_selection.py`.
    help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()
    created = await session_service.create_session(
        db_session,
        tutor,
        SessionCreate(
            help_request_id=request.id,
            course_unit_id=course_unit.public_id,
            topic="sorting",
            duration_minutes=45,
        ),
    )

    started = await _start_session(db_session, created, student)
    completed = await session_service.transition_session(
        db_session,
        tutor,
        started.id,
        SessionTransitionRequest(status=SessionStatus.COMPLETED),
    )

    assert completed.status is SessionStatus.COMPLETED
    assert completed.duration_minutes >= 1
    assert completed.ended_at is not None
    assert completed.is_rated is False

    session_row = await db_session.scalar(
        select(Session).where(Session.public_id == created.id)
    )
    assert session_row is not None and session_row.status is SessionStatus.COMPLETED


async def test_completing_through_the_lifecycle_banks_minutes_and_counts_the_session(
    db_session,
):
    """The accrual has to happen on the path a client actually takes.

    Every other test of the tutor's counters seeds `completed_sessions` and
    `certified_minutes` directly, so the wiring between `transition_session` and
    `record_completion` was never asserted by anything. It was broken: the
    transition passed a row that was not yet `completed` to a function that
    banks only completed sessions, so it returned early every time and both
    counters stayed at zero no matter how many sessions a tutor taught.

    The consequence was not only a certificate nobody could earn. `completed_
    sessions` is half of the promotion gate, so `_recompute_standing` read zero
    and pinned every tutor at `probationary` for the life of the account --
    invariant that verified standing is earned, never claimed, was unreachable
    through the app.

    Three sessions, because three is the promotion threshold: the gate is what
    this pins, and a test asserting one session would still pass with the
    counter stuck at one forever.
    """
    student, tutor, course_unit = await _seed_session_data(db_session)
    profile = await db_session.scalar(
        select(TutorProfile).where(TutorProfile.user_id == tutor.id)
    )
    assert profile is not None
    sessions_before = profile.completed_sessions
    minutes_before = profile.certified_minutes

    banked = 0
    for index in range(3):
        request = await matching_service.create_help_request(
            db_session,
            student,
            HelpRequestCreate(
                course_unit_id=course_unit.public_id, topic=f"topic {index}"
            ),
        )
        help_request = await db_session.scalar(
            select(HelpRequest).where(HelpRequest.public_id == request.id)
        )
        help_request.matched_tutor_id = tutor.id
        help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
        await db_session.commit()
        created = await session_service.create_session(
            db_session,
            tutor,
            SessionCreate(
                help_request_id=request.id,
                course_unit_id=course_unit.public_id,
                topic=f"topic {index}",
                duration_minutes=30,
            ),
        )
        started = await _start_session(db_session, created, student)
        completed = await session_service.transition_session(
            db_session,
            tutor,
            started.id,
            SessionTransitionRequest(status=SessionStatus.COMPLETED),
        )
        banked += completed.duration_minutes

    await db_session.refresh(profile)
    assert banked > 0
    assert profile.completed_sessions == sessions_before + 3
    assert profile.certified_minutes == minutes_before + banked


async def test_a_session_is_banked_once_even_across_repeated_calls(db_session):
    """The accrual is not a function of how often a client asks.

    `SESSION_TRANSITIONS` gives `completed` an empty allowed set, so a second
    `completed` transition is refused before it reaches the accrual. The counter
    is asserted directly rather than through the rejection so that the reason
    the guard exists is visible: a completed session that could be banked twice
    would inflate both the hours behind a certificate and the session count
    behind promotion, and inflating either is a way to earn standing.
    """
    student, tutor, course_unit = await _seed_session_data(db_session)
    profile = await db_session.scalar(
        select(TutorProfile).where(TutorProfile.user_id == tutor.id)
    )
    assert profile is not None
    sessions_before = profile.completed_sessions
    minutes_before = profile.certified_minutes
    request = await matching_service.create_help_request(
        db_session,
        student,
        HelpRequestCreate(course_unit_id=course_unit.public_id, topic="sorting"),
    )
    help_request = await db_session.scalar(
        select(HelpRequest).where(HelpRequest.public_id == request.id)
    )
    help_request.matched_tutor_id = tutor.id
    help_request.status = HelpRequestStatus.PENDING_CONFIRMATION
    await db_session.commit()
    created = await session_service.create_session(
        db_session,
        tutor,
        SessionCreate(
            help_request_id=request.id,
            course_unit_id=course_unit.public_id,
            topic="sorting",
            duration_minutes=45,
        ),
    )
    started = await _start_session(db_session, created, student)
    completed = await session_service.transition_session(
        db_session,
        tutor,
        started.id,
        SessionTransitionRequest(status=SessionStatus.COMPLETED),
    )
    banked = completed.duration_minutes

    with pytest.raises(ValidationProblem):
        await session_service.transition_session(
            db_session,
            tutor,
            started.id,
            SessionTransitionRequest(status=SessionStatus.COMPLETED),
        )

    await db_session.refresh(profile)
    assert profile.completed_sessions == sessions_before + 1
    assert profile.certified_minutes == minutes_before + banked
