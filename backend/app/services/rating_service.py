"""Tutor rating and standing updates."""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from decimal import Decimal

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.exceptions import (
    AuthorizationProblem,
    NotFoundProblem,
    ValidationProblem,
)
from app.models.course_unit import CourseUnit
from app.models.endorsement import UnitEndorsement
from app.models.enums import SessionStatus, TutorStanding
from app.models.rating import Rating
from app.models.session import Session
from app.models.tutor_profile import TutorProfile
from app.models.user import User
from app.schemas.rating import (
    RatingCreate,
    RatingResponse,
    TutorRatingSummary,
    UnitEndorsementCount,
)

PROMOTION_MIN_SESSIONS = 3
PROMOTION_MIN_AVERAGE = Decimal("4.10")


async def submit_rating(
    db: AsyncSession,
    user: User,
    session_id: uuid.UUID,
    payload: RatingCreate,
) -> RatingResponse:
    """Write or update a session rating and recalculate the tutor's standing.

    Endorsements ride along on the same submission and are written in the same
    transaction as the rating. Splitting them would leave a window in which a
    rating exists without its endorsements, or the reverse, and the per-unit
    aggregate would be answering from a half-written answer.
    """
    session = await _load_session_for_user(db, user, session_id)
    if session.status is not SessionStatus.COMPLETED:
        raise ValidationProblem(
            "Only completed sessions can be rated.",
            errors={"session_id": "must be completed"},
        )

    if user.id not in {session.tutee_id, session.tutor_id}:
        raise AuthorizationProblem("You are not part of this session.")

    ratee_id = session.tutor_id if user.id == session.tutee_id else session.tutee_id
    # Resolved before anything is written, so a rejected endorsement cannot leave
    # a rating behind without the endorsement the caller asked for.
    endorsed_course_unit_ids = await _resolve_endorsed_course_units(
        db, session, payload.endorsed_course_unit_ids
    )
    result = await db.execute(
        select(Rating)
        .where(Rating.session_id == session.id, Rating.rater_id == user.id)
        .options(
            selectinload(Rating.session),
            selectinload(Rating.rater),
            selectinload(Rating.ratee),
        )
    )
    existing = result.scalar_one_or_none()

    if existing is None:
        rating = Rating(
            session_id=session.id,
            rater_id=user.id,
            ratee_id=ratee_id,
            score=payload.score,
            feedback_text=payload.feedback_text,
        )
        db.add(rating)
        await _replace_endorsements(
            db,
            session=session,
            rater_id=user.id,
            ratee_id=ratee_id,
            course_unit_ids=endorsed_course_unit_ids,
        )
        profile = await _tutor_profile_for_ratee(db, session, ratee_id)
        if profile is not None:
            profile.rating_total += Decimal(str(payload.score))
            profile.rating_count += 1
            await _recompute_standing(db, profile)
        await db.flush()
        await db.commit()
        await db.refresh(rating)
        return RatingResponse.model_validate(rating)

    previous_score = Decimal(str(existing.score))
    existing.score = payload.score
    existing.feedback_text = payload.feedback_text
    await _replace_endorsements(
        db,
        session=session,
        rater_id=user.id,
        ratee_id=ratee_id,
        course_unit_ids=endorsed_course_unit_ids,
    )
    profile = await _tutor_profile_for_ratee(db, session, ratee_id)
    if profile is not None:
        profile.rating_total = (
            profile.rating_total - previous_score + Decimal(str(payload.score))
        )
        await _recompute_standing(db, profile)
    await db.flush()
    await db.commit()
    await db.refresh(existing)
    return RatingResponse.model_validate(existing)


async def _resolve_endorsed_course_units(
    db: AsyncSession,
    session: Session,
    endorsed_public_ids: list[uuid.UUID],
) -> list[uuid.UUID]:
    """Map endorsed public course unit ids to internal keys, or reject them.

    Only the session's own unit is acceptable, and that is a rule about the world
    rather than about the payload: a session is booked for one course unit, so
    endorsing any other is either a client that guessed or a claim about a
    session that did not happen. A cross-unit endorsement would also mean the
    unit being endorsed and the unit that generated it could disagree, and the
    per-unit aggregate would then be counting something no session backs.

    Widening this to several units is a deliberate future change, not an
    oversight. It needs a session to be about several units, and that is a change
    to `sessions` and the booking flow rather than to this function.

    Returns internal keys in the order submitted. Duplicates have already been
    refused by `RatingCreate`, and the unique constraint on the table is the
    backstop behind that; this function does not silently collapse them, because
    a caller that sends one twice should have been told rather than quietly
    given one endorsement.
    """
    if not endorsed_public_ids:
        return []

    result = await db.execute(
        select(CourseUnit.id, CourseUnit.public_id).where(
            CourseUnit.public_id.in_(endorsed_public_ids)
        )
    )
    internal_by_public_id = {
        public_id: course_unit_id for course_unit_id, public_id in result.all()
    }

    resolved: list[uuid.UUID] = []
    for public_id in endorsed_public_ids:
        course_unit_id = internal_by_public_id.get(public_id)
        if course_unit_id is None:
            raise ValidationProblem(
                "One of the endorsed course units could not be found.",
                errors={
                    "endorsed_course_unit_ids": (f"{public_id} is not a course unit.")
                },
            )
        if course_unit_id != session.course_unit_id:
            raise ValidationProblem(
                "A session can only endorse the course unit it was held for.",
                errors={
                    "endorsed_course_unit_ids": (
                        f"{public_id} is not the course unit this session covered."
                    )
                },
            )
        resolved.append(course_unit_id)
    return resolved


async def _replace_endorsements(
    db: AsyncSession,
    *,
    session: Session,
    rater_id: uuid.UUID,
    ratee_id: uuid.UUID,
    course_unit_ids: list[uuid.UUID],
) -> None:
    """Leave exactly `course_unit_ids` endorsed by this rater for this session.

    Replace rather than merge, because the second submission is the rater
    correcting the first. A rater who removes a unit from their endorsement list
    is saying they no longer hold that claim, and a merge would leave the claim
    standing in the aggregate forever with no way to withdraw it.

    Deletes in one statement rather than by walking the collection. This is the
    `passive_deletes` behaviour done explicitly: the rows are removed by the
    database and never loaded into the ORM to be deleted one at a time.

    The delete runs before the inserts are added, so a re-submission of the same
    unit deletes the row it is about to replace rather than colliding with it on
    the unique key.
    """
    await db.execute(
        delete(UnitEndorsement).where(
            UnitEndorsement.session_id == session.id,
            UnitEndorsement.rater_id == rater_id,
        )
    )
    for course_unit_id in course_unit_ids:
        db.add(
            UnitEndorsement(
                session_id=session.id,
                rater_id=rater_id,
                ratee_id=ratee_id,
                course_unit_id=course_unit_id,
            )
        )


async def get_tutor_rating_summary(
    db: AsyncSession,
    user: User,
) -> TutorRatingSummary:
    """The aggregate rating summary the tutor profile is built from.

    A user with no profile is not a tutor yet, so the summary reports the
    zeroed counters rather than minting a profile on a read. `GET` must never
    change state: a summary that created a row would hand every signed-in
    student a standing, and would do it merely by opening a screen.
    """
    result = await db.execute(
        select(TutorProfile).where(TutorProfile.user_id == user.id)
    )
    profile = result.scalar_one_or_none()
    # A detached instance carries the same zeroed counters a fresh one would,
    # and is never added to the session, so nothing is written. The zero values
    # are stated rather than left to the column defaults, because those only
    # apply on flush and this instance is deliberately never flushed.
    if profile is None:
        profile = TutorProfile(
            user_id=user.id,
            standing=TutorStanding.PROBATIONARY,
            completed_sessions=0,
            certified_minutes=0,
            rating_total=Decimal("0"),
            rating_count=0,
        )

    result = await db.execute(
        select(Rating)
        .where(Rating.ratee_id == user.id)
        .options(
            selectinload(Rating.session),
            selectinload(Rating.rater),
            selectinload(Rating.ratee),
        )
        .order_by(Rating.created_at.desc())
        .limit(20)
    )
    recent = [RatingResponse.model_validate(row) for row in result.scalars()]
    per_unit = await _load_unit_endorsement_counts(db, user.id)
    return TutorRatingSummary(
        average_rating=profile.average_rating,
        rating_total=profile.rating_total,
        rating_count=profile.rating_count,
        recent=recent,
        per_unit=per_unit,
    )


async def _load_unit_endorsement_counts(
    db: AsyncSession, user_id: uuid.UUID
) -> list[UnitEndorsementCount]:
    """Endorsement counts per course unit for one tutor.

    Thin wrapper over the shared aggregation rather than the implementation of
    it, so a second caller cannot end up with a subtly different definition of
    "endorsed".
    """
    return (await load_unit_endorsement_counts(db, [user_id])).get(user_id, [])


async def load_unit_endorsement_counts(
    db: AsyncSession, user_ids: Sequence[uuid.UUID]
) -> dict[uuid.UUID, list[UnitEndorsementCount]]:
    """Endorsement counts per course unit, for several tutors at once.

    Keyed by the caller's *internal* user id, because that is what the callers
    already hold -- a row fetched by a query, not one the client sent -- and the
    values carry public course unit ids, because that is what the client can act
    on. Two different id spaces in one return value is a wart worth naming: the
    key is an internal join key and is never serialised, while everything
    inside a list is wire data.

    Several tutors in one query is the point. The tutor rail reads this for
    every row it shows at once, and a per-tutor call would make that a query
    proportional to the length of the rail -- the same N+1 that
    `_load_unit_endorsement_counts` was written to avoid for one tutor.

    Joined to `course_units` for the public id rather than reporting the
    endorsement's own `course_unit_id`, so the aggregate cannot hand a client an
    internal key. Counting in the database rather than loading the rows is what
    keeps this proportional to the number of units a tutor has taught in rather
    than to their whole session history.

    Units with no endorsements do not appear at all: there is no row to group,
    and a zero would read as "endorsed here and rated badly" rather than as
    "no evidence". Ordering is count descending, then course code, so the
    response is stable across calls and a test on it cannot flake. The sort is
    over the whole result rather than per tutor, which is the same order: a
    query sorted by (count, code) is still sorted by (count, code) when read
    back one `ratee_id` at a time.
    """
    if not user_ids:
        return {}

    result = await db.execute(
        select(
            CourseUnit.public_id,
            UnitEndorsement.ratee_id,
            func.count(UnitEndorsement.id),
        )
        .join(UnitEndorsement, UnitEndorsement.course_unit_id == CourseUnit.id)
        .where(UnitEndorsement.ratee_id.in_(list(user_ids)))
        .group_by(
            CourseUnit.id,
            CourseUnit.public_id,
            CourseUnit.code,
            UnitEndorsement.ratee_id,
        )
        .order_by(func.count(UnitEndorsement.id).desc(), CourseUnit.code)
    )
    counts: dict[uuid.UUID, list[UnitEndorsementCount]] = {}
    for public_id, ratee_id, count in result.all():
        counts.setdefault(ratee_id, []).append(
            UnitEndorsementCount(course_unit_id=public_id, endorsement_count=count)
        )
    return counts


async def _load_session_for_user(
    db: AsyncSession,
    user: User,
    session_id: uuid.UUID,
) -> Session:
    result = await db.execute(
        select(Session)
        .where(Session.public_id == session_id)
        .options(
            selectinload(Session.tutee),
            selectinload(Session.tutor),
            selectinload(Session.course_unit),
            selectinload(Session.help_request),
        )
    )
    session = result.scalar_one_or_none()
    if session is None:
        raise NotFoundProblem("That session could not be found.")
    if session.tutee_id != user.id and session.tutor_id != user.id:
        raise AuthorizationProblem("You are not part of that session.")
    return session


async def _tutor_profile_for_ratee(
    db: AsyncSession, session: Session, ratee_id: uuid.UUID
) -> TutorProfile | None:
    """The ratee's tutor profile, or `None` when the ratee is not the tutor.

    Both parties can rate a completed session, so `ratee_id` is whichever of
    them did not press the button. Standing and the running average describe a
    *tutor*, and a tutee who rated their tutor has no profile to update: creating
    one would silently promote a student into a standing they were never
    assessed for, and would count the score against their record. Returning
    `None` keeps the rating itself -- which is real feedback about the session
    and belongs to whoever gave it -- while leaving standing untouched.

    `validation_service` is the only thing that grants the TUTOR role and creates
    the first profile, on a verified competency. A rating is not a route to
    becoming a tutor.
    """
    if ratee_id != session.tutor_id:
        return None
    return await _get_or_create_tutor_profile(db, ratee_id)


async def _get_or_create_tutor_profile(
    db: AsyncSession, user_id: uuid.UUID
) -> TutorProfile:
    result = await db.execute(
        select(TutorProfile).where(TutorProfile.user_id == user_id)
    )
    profile = result.scalar_one_or_none()
    if profile is None:
        profile = TutorProfile(user_id=user_id)
        db.add(profile)
        await db.flush()
    return profile


async def _recompute_standing(db: AsyncSession, profile: TutorProfile) -> None:
    if (
        profile.completed_sessions < PROMOTION_MIN_SESSIONS
        or profile.average_rating is None
    ):
        profile.standing = TutorStanding.PROBATIONARY
        return

    if profile.average_rating >= PROMOTION_MIN_AVERAGE:
        profile.standing = TutorStanding.VERIFIED
    else:
        profile.standing = TutorStanding.REDUCED


async def record_completion(db: AsyncSession, session: Session) -> None:
    """Persist the completed-session counters that support promotion and
    certificate totals.
    """
    if session.status is not SessionStatus.COMPLETED:
        return
    profile = await _get_or_create_tutor_profile(db, session.tutor_id)
    profile.completed_sessions += 1
    profile.certified_minutes += max(session.duration_minutes, 0)
    await _recompute_standing(db, profile)


async def list_recent_ratings(
    db: AsyncSession,
    user: User,
    *,
    limit: int = 20,
) -> list[RatingResponse]:
    """Most recent ratings received by the current tutor."""
    result = await db.execute(
        select(Rating)
        .where(Rating.ratee_id == user.id)
        .options(
            selectinload(Rating.session),
            selectinload(Rating.rater),
            selectinload(Rating.ratee),
        )
        .order_by(Rating.created_at.desc())
        .limit(limit)
    )
    return [RatingResponse.model_validate(row) for row in result.scalars()]
