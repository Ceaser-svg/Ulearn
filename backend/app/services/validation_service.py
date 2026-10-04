"""Tutor validation and competency verification business logic."""

import uuid
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.exceptions import NotFoundProblem, ValidationProblem
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, University
from app.models.enums import CompetencyStatus
from app.models.grading_scale import Grade
from app.models.user import User
from app.schemas.competency import CompetencyCreate, CompetencyResponse

#: Everything `_competency_response` reads, in one place.
#:
#: The response builder is a plain function, so it cannot await a lazy load. When
#: a query omitted one of these the request failed with `MissingGreenlet` while
#: building its own response -- and under the suite's shared-session fixture it
#: did not fail at all, because the identity map already held the rows from an
#: earlier call in the same test. Declaring the set once means a new query cannot
#: quietly forget part of it.
_COMPETENCY_LOAD = (
    selectinload(Competency.user),
    selectinload(Competency.grade),
    selectinload(Competency.course_unit)
    .selectinload(CourseUnit.university)
    .selectinload(University.grading_scale),
)


async def list_competencies(db: AsyncSession, user: User) -> list[CompetencyResponse]:
    """Every competency this user has submitted."""
    result = await db.execute(
        select(Competency)
        .where(Competency.user_id == user.id)
        .options(*_COMPETENCY_LOAD)
        .order_by(Competency.created_at.desc())
    )
    return [_competency_response(row) for row in result.scalars()]


async def get_competency(
    db: AsyncSession, user: User, competency_id: uuid.UUID
) -> CompetencyResponse:
    """One competency, when the caller owns it."""
    return _competency_response(await _load_competency(db, user, competency_id))


async def _load_competency(
    db: AsyncSession, user: User, competency_id: uuid.UUID
) -> Competency:
    """One competency the caller owns, loaded for the response builder.

    The filter is on `public_id` because that is the only id a client is ever
    given. Filtering on the internal primary key made this route unreachable:
    every request carried a public UUID, matched nothing, and returned 404.
    """
    result = await db.execute(
        select(Competency)
        .where(Competency.public_id == competency_id, Competency.user_id == user.id)
        .options(*_COMPETENCY_LOAD)
    )
    competency = result.scalar_one_or_none()
    if competency is None:
        raise NotFoundProblem("That competency record could not be found.")
    return competency


async def create_competency(
    db: AsyncSession,
    user: User,
    payload: CompetencyCreate,
) -> CompetencyResponse:
    """Submit a tutor's grade proof for a single course unit."""
    if user.academic_data_consented_at is None:
        raise ValidationProblem(
            "Academic-data consent is required before submitting transcript proof.",
            errors={"academic_data_consented": "consent is required"},
        )

    if user.university_id is None:
        raise ValidationProblem(
            "Choose your university before submitting tutor verification.",
            errors={"university_id": "university is required"},
        )

    course_unit = await _load_course_unit(db, payload.course_unit_id)
    if course_unit.university_id != user.university_id:
        raise ValidationProblem(
            "That course unit does not belong to the student's university.",
            errors={"course_unit_id": "must match the student's university"},
        )

    grade = await _load_grade(db, payload.grade_id)
    if course_unit.university.grading_scale_id is None:
        raise ValidationProblem(
            "This university has not published a grading scale yet.",
            errors={"university_id": "grading scale is missing"},
        )
    if grade.grading_scale_id != course_unit.university.grading_scale_id:
        raise ValidationProblem(
            "That grade does not belong to the unit's university scale.",
            errors={"grade_id": "must match the unit's grading scale"},
        )

    existing = await db.scalar(
        select(Competency.id).where(
            Competency.user_id == user.id,
            Competency.course_unit_id == course_unit.id,
        )
    )
    if existing is not None:
        raise ValidationProblem(
            "A competency already exists for this unit.",
            errors={"course_unit_id": "duplicate competency"},
        )

    competency = Competency(
        user_id=user.id,
        course_unit_id=course_unit.id,
        grade_id=grade.id,
        status=CompetencyStatus.PENDING,
        source=payload.source,
        evidence_reference=payload.evidence_reference,
        notes=payload.notes,
    )
    db.add(competency)
    await db.flush()
    await db.commit()
    # Re-read rather than building the response off the flushed instance: the
    # relationships `_competency_response` walks are not populated on a row that
    # has only just been inserted, and the builder is synchronous.
    return _competency_response(await _load_competency(db, user, competency.public_id))


def _utcnow():
    from datetime import UTC, datetime

    return datetime.now(UTC)


async def _load_course_unit(db: AsyncSession, public_id: uuid.UUID) -> CourseUnit:
    result = await db.execute(
        select(CourseUnit)
        .where(CourseUnit.public_id == public_id)
        .options(selectinload(CourseUnit.university))
    )
    course_unit = result.scalar_one_or_none()
    if course_unit is None:
        raise NotFoundProblem("That course unit could not be found.")
    return course_unit


async def _load_grade(db: AsyncSession, public_id: uuid.UUID) -> Grade:
    result = await db.execute(select(Grade).where(Grade.public_id == public_id))
    grade = result.scalar_one_or_none()
    if grade is None:
        raise NotFoundProblem("That grade could not be found.")
    return grade


def _competency_response(competency: Competency) -> CompetencyResponse:
    scale = competency.course_unit.university.grading_scale
    minimum_points = scale.competency_min_points if scale is not None else Decimal("0")
    return CompetencyResponse.model_validate(
        {
            "id": competency.public_id,
            "user_id": competency.user_public_id,
            "course_unit_id": competency.course_unit_public_id,
            "grade_id": competency.grade_public_id,
            "status": competency.status,
            "source": competency.source,
            "grade_points": competency.grade.grade_points,
            "meets_threshold": (
                competency.status is CompetencyStatus.VERIFIED
                and competency.grade.grade_points >= minimum_points
            ),
            "verified_at": competency.verified_at,
            "rejection_reason": competency.rejection_reason,
            "evidence_reference": competency.evidence_reference,
            "created_at": competency.created_at,
        }
    )
