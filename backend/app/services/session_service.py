"""Tutoring session lifecycle business logic."""

import secrets
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.exceptions import (
    AuthorizationProblem,
    ConflictProblem,
    NotFoundProblem,
    TooManyRequestsProblem,
    ValidationProblem,
)
from app.models.course_unit import CourseUnit
from app.models.enums import (
    SESSION_TRANSITIONS,
    HelpRequestStatus,
    SessionStatus,
    UserRole,
)
from app.models.session import HelpRequest, Session
from app.models.user import User, has_role, load_roles
from app.schemas.session import (
    SessionCreate,
    SessionPinResponse,
    SessionResponse,
    SessionTransitionRequest,
)
from app.services import rating_service

#: Wrong entries before the tutee is put on a cooldown.
#:
#: Low, deliberately. The pin is two digits, so the whole search space is 100 and
#: a generous limit is barely a limit: at 5, a full sweep of the space costs a
#: minute of waiting. The handshake proves the tutee was in the room; it is not a
#: security control, so a handful of tries suits it and the tutor has to be
#: standing there.
MAX_PIN_ATTEMPTS = 5

#: How long a tutee is locked out once they have used them all.
#:
#: A cooldown rather than a permanent lock, because the session still has to be
#: startable and both parties are physically present. Fifteen minutes is long
#: enough that brute-forcing 100 candidates is pointless and short enough that a
#: genuine typo is not a dead session.
PIN_LOCKOUT = timedelta(minutes=15)


def _utc(dt: datetime) -> datetime:
    """Normalize to UTC so SQLite and PostgreSQL agree on the same instant."""
    if dt.tzinfo is None:
        return dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


async def create_session(
    db: AsyncSession,
    user: User,
    payload: SessionCreate,
) -> SessionResponse:
    """Confirm a selected help request and create the session for it.

    The tutor confirms; they do not claim. A session used to be creatable by any
    tutor against any unselected request, which set `matched_tutor_id` to the
    caller and left the student never asked -- the inverse of MVP decision 3, and
    the one place a tutor could take work the student had refused them. Only the
    tutor the student already named may confirm, and only from the state that says
    the student is waiting on them.

    The session is not the primary flow for the MVP: a real tutoring session always
    starts from a problem the student asked for.
    """
    roles = await load_roles(db, user.id)
    if not has_role(roles, UserRole.TUTOR):
        raise AuthorizationProblem("Only tutors can accept a session.")

    if payload.help_request_id is None:
        raise ValidationProblem(
            "A session must be linked to a help request.",
            errors={"help_request_id": "required"},
        )

    help_request = await _load_help_request(db, payload.help_request_id)
    if help_request.tutee_id == user.id:
        raise AuthorizationProblem("The student cannot create the accepted session.")
    if help_request.matched_tutor_id != user.id:
        raise AuthorizationProblem(
            "Only the tutor the student chose can confirm this request."
        )
    # One confirmation per request, and only out of `PENDING_CONFIRMATION`. This
    # is also where `MATCHED` is refused: a retried POST is ordinary on a phone,
    # and re-accepting would hand the student a second session for one question.
    if help_request.status is not HelpRequestStatus.PENDING_CONFIRMATION:
        raise ConflictProblem(
            "This help request is not waiting for this tutor's confirmation."
        )

    course_unit = await _load_course_unit(db, payload.course_unit_id)
    if course_unit.id != help_request.course_unit_id:
        raise ValidationProblem(
            "The session course unit must match the help request.",
            errors={"course_unit_id": "must match the request"},
        )

    # The `session_per_request` unique constraint is the real guarantee -- two
    # simultaneous requests would both pass a check made of a read -- and this is
    # what turns the loser of that race into a 409 rather than a 500.
    existing = await db.scalar(
        select(Session.id).where(Session.help_request_id == help_request.id)
    )
    if existing is not None:
        raise ConflictProblem("That help request already has an accepted session.")

    session = Session(
        help_request_id=help_request.id,
        tutee_id=help_request.tutee_id,
        tutor_id=user.id,
        course_unit_id=course_unit.id,
        topic=payload.topic or help_request.topic,
        scheduled_start=payload.scheduled_start,
        duration_minutes=payload.duration_minutes,
        session_pin=Session.generate_session_pin(),
        meeting_link=(payload.meeting_link or "").strip() or None,
        status=SessionStatus.SCHEDULED,
    )
    db.add(session)
    help_request.status = HelpRequestStatus.MATCHED
    help_request.matched_tutor_id = user.id
    await db.flush()
    await db.commit()
    await db.refresh(session)
    return await _session_response(db, session)


async def list_sessions(
    db: AsyncSession,
    user: User,
    *,
    include_cancelled: bool = True,
) -> list[SessionResponse]:
    """Every session the signed-in user is part of."""
    query = (
        select(Session)
        .where((Session.tutee_id == user.id) | (Session.tutor_id == user.id))
        .options(
            selectinload(Session.help_request),
            selectinload(Session.tutee),
            selectinload(Session.tutor),
            selectinload(Session.course_unit),
        )
        .order_by(Session.created_at.desc())
    )
    if not include_cancelled:
        query = query.where(Session.status != SessionStatus.CANCELLED)
    result = await db.execute(query)
    return [await _session_response(db, row) for row in result.scalars()]


async def get_session(
    db: AsyncSession, user: User, session_id: uuid.UUID
) -> SessionResponse:
    """Fetch one session the current user can view."""
    session = await _load_session_for_user(db, user, session_id)
    return await _session_response(db, session)


async def transition_session(
    db: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    payload: SessionTransitionRequest,
) -> SessionResponse:
    """Move a session through its allowed lifecycle states."""
    session = await _load_session_for_user(db, user, session_id)
    allowed = SESSION_TRANSITIONS.get(session.status, frozenset())
    if payload.status not in allowed:
        raise ValidationProblem(
            "That session status change is not allowed.",
            errors={
                "status": f"{session.status.value} -> {payload.status.value} is invalid"
            },
        )

    if payload.status is SessionStatus.IN_PROGRESS:
        # Starting used to be accepted here too, with a `pin` field checked
        # inline. Two problems, and the first is why this is now a refusal
        # rather than a second code path:
        #
        # - It was a bypass. This branch had no attempt counter and no cooldown,
        #   so the throttle in `verify_session_pin` could be walked around by
        #   calling this instead, making the lockout decoration.
        # - It let either party start a session. Under the rule that the tutor
        #   reveals and the tutee enters, a tutor calling this has simply told
        #   the server the session is live.
        #
        # One code path means the throttle cannot be circumvented by accident.
        raise ValidationProblem(
            "Use the PIN endpoint to start this session.",
            errors={"status": "in_progress requires verify-pin"},
        )

    if payload.status is SessionStatus.COMPLETED:
        if session.started_at is None:
            raise ValidationProblem(
                "The session must start before it can be completed.",
                errors={"status": "in_progress required"},
            )
        session.ended_at = _utc(session.ended_at or datetime.now(UTC))
        elapsed = int(
            (_utc(session.ended_at) - _utc(session.started_at)).total_seconds() // 60
        )
        session.duration_minutes = max(1, elapsed)

    if payload.status is SessionStatus.CANCELLED:
        session.cancelled_by_id = user.id
        session.cancellation_reason = payload.cancellation_reason

    if payload.status is not SessionStatus.CANCELLED:
        session.cancelled_by_id = None
        session.cancellation_reason = None

    # The status is assigned before `record_completion` runs, not after. That
    # function banks minutes only for a session that is already `completed` and
    # returns early otherwise, so calling it against the pre-transition row
    # silently did nothing: no session ever accrued a minute, `completed_sessions`
    # stayed at zero, and with it `_recompute_standing` held every tutor at
    # `probationary` forever. `SESSION_TRANSITIONS` gives `completed` an empty
    # allowed set, so arriving here with this status means the row was not
    # already completed and the accrual happens exactly once.
    session.status = payload.status
    if payload.status is SessionStatus.COMPLETED:
        await rating_service.record_completion(db, session)

    await db.flush()
    await db.commit()
    return await _session_response(db, session)


async def reveal_session_pin(
    db: AsyncSession,
    user: User,
    session_id: uuid.UUID,
) -> SessionPinResponse:
    """Hand the handshake PIN to the tutor, and to nobody else.

    The tutee is refused here. That refusal is the whole point of the handshake:
    if a tutee could read their own PIN, there would be nothing to prove, and the
    tutor would have no way to tell an in-person student from someone guessing
    two digits on a stolen account.
    """
    session = await _load_session_for_user(db, user, session_id)
    if session.tutor_id != user.id:
        raise AuthorizationProblem("Only the tutor can see the session PIN.")

    # Stays available until the session starts. Revealing it earlier would let a
    # tutor collect PINs in advance, which is a use the handshake cannot detect.
    if session.status is not SessionStatus.SCHEDULED:
        raise ConflictProblem("This session has already started.")

    pin = (session.session_pin or "").strip()
    if not pin:
        raise ConflictProblem("This session has no handshake PIN to reveal.")

    return SessionPinResponse(
        session_id=session.public_id,
        session_pin=pin,
        attempts_remaining=max(0, MAX_PIN_ATTEMPTS - session.pin_failed_attempts),
    )


def _pin_lock_remaining(session: Session) -> int:
    """Seconds until the tutee may try again, or 0 if they may try now."""
    if session.pin_locked_until is None:
        return 0
    remaining = (
        _utc(session.pin_locked_until) - _utc(datetime.now(UTC))
    ).total_seconds()
    return int(remaining) + 1 if remaining > 0 else 0


async def verify_session_pin(
    db: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    pin: str,
) -> SessionResponse:
    """The tutee enters the two digits the tutor read out, starting the session.

    Throttled on the row. The pin has 100 possible values, so without a ceiling
    this endpoint is a free oracle: a caller can walk the whole space in a second
    and start any session they are a party to.
    """
    session = await _load_session_for_user(db, user, session_id)

    # The tutor already has the PIN. Letting them enter it would make the check
    # something they pass on their own, so the two directions are exclusive.
    if session.tutee_id != user.id:
        raise AuthorizationProblem("Only the student can enter the session PIN.")

    if session.status is not SessionStatus.SCHEDULED:
        raise ConflictProblem("This session is not waiting to start.")

    waiting = _pin_lock_remaining(session)
    if waiting:
        raise TooManyRequestsProblem(
            "Too many wrong PINs. Wait before trying again.",
            retry_after_seconds=waiting,
        )

    # Fails closed: a session with no stored PIN must reject every candidate,
    # including a blank one, rather than treating "no PIN" as "PIN matches".
    expected = (session.session_pin or "").strip()
    if not expected or not secrets.compare_digest(pin.strip(), expected):
        session.pin_failed_attempts += 1
        if session.pin_failed_attempts >= MAX_PIN_ATTEMPTS:
            session.pin_locked_until = _utc(datetime.now(UTC) + PIN_LOCKOUT)
        # Committed rather than left to a rollback. An attempt that is not counted
        # is an attempt that is free, and the error path is exactly where an
        # uncommitted counter would be silently discarded.
        await db.commit()
        raise ValidationProblem(
            "The session PIN is incorrect.",
            errors={"pin": "incorrect"},
        )

    # Reset on success so a later handshake on the same row is not punished for
    # typos the tutee already recovered from.
    session.pin_failed_attempts = 0
    session.pin_locked_until = None
    session.status = SessionStatus.IN_PROGRESS
    session.started_at = _utc(session.started_at or datetime.now(UTC))
    await db.flush()
    await db.commit()
    return await _session_response(db, session)


async def _load_help_request(db: AsyncSession, request_id: uuid.UUID) -> HelpRequest:
    """Fetch one help request, eagerly loading the joined rows it exposes."""
    result = await db.execute(
        select(HelpRequest)
        .where(HelpRequest.public_id == request_id)
        .options(
            selectinload(HelpRequest.tutee),
            selectinload(HelpRequest.course_unit),
            selectinload(HelpRequest.matched_tutor),
        )
    )
    request = result.scalar_one_or_none()
    if request is None:
        raise NotFoundProblem("That help request could not be found.")
    return request


async def _load_course_unit(db: AsyncSession, course_unit_id: uuid.UUID) -> CourseUnit:
    """Fetch one course unit by public id."""
    result = await db.execute(
        select(CourseUnit).where(CourseUnit.public_id == course_unit_id)
    )
    course_unit = result.scalar_one_or_none()
    if course_unit is None:
        raise NotFoundProblem("That course unit could not be found.")
    return course_unit


async def _load_session_for_user(
    db: AsyncSession,
    user: User,
    session_id: uuid.UUID,
) -> Session:
    """Load a session only when the caller is one of the parties."""
    result = await db.execute(
        select(Session)
        .where(Session.public_id == session_id)
        .options(
            selectinload(Session.help_request),
            selectinload(Session.tutee),
            selectinload(Session.tutor),
            selectinload(Session.course_unit),
        )
    )
    session = result.scalar_one_or_none()
    if session is None:
        raise NotFoundProblem("That session could not be found.")
    if session.tutee_id != user.id and session.tutor_id != user.id:
        raise AuthorizationProblem("You do not have access to that session.")
    return session


async def _session_response(db: AsyncSession, session: Session) -> SessionResponse:
    """Build the response with a computed rating flag."""
    return SessionResponse(
        id=session.public_id,
        help_request_id=(
            session.help_request.public_id if session.help_request else None
        ),
        tutee_id=session.tutee.public_id,
        tutor_id=session.tutor.public_id,
        course_unit_id=session.course_unit.public_id,
        topic=session.topic,
        status=session.status,
        scheduled_start=session.scheduled_start,
        started_at=session.started_at,
        ended_at=session.ended_at,
        duration_minutes=session.duration_minutes,
        meeting_link=session.meeting_link,
        is_rated=await session.is_rated(db),
        created_at=session.created_at,
    )
