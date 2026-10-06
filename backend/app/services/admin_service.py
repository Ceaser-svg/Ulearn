"""Least-privilege read and audit operations for MUST staff."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.exceptions import NotFoundProblem, ValidationProblem
from app.models.audit import AdminAuditEvent
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, University
from app.models.enums import CompetencyStatus
from app.models.tutor_profile import TutorProfile
from app.models.user import User, load_roles
from app.schemas.admin import (
    AdminAuditEventPage,
    AdminAuditEventResponse,
    AdminCompetencyPage,
    AdminCompetencyPageParams,
    AdminCompetencyResponse,
    AdminCompetencyReviewRequest,
    AdminTutorStandingPage,
    AdminTutorStandingResponse,
    AdminUserPage,
    AdminUserResponse,
)
from app.schemas.common import PageParams


async def list_users(
    db: AsyncSession, actor_id: uuid.UUID, params: PageParams
) -> AdminUserPage:
    """List users without passwords, tokens, consent timestamps, or evidence."""
    query = (
        select(User)
        .options(selectinload(User.university), selectinload(User.faculty))
        .order_by(User.created_at.desc(), User.id.desc())
    )
    total = await db.scalar(select(func.count()).select_from(query.subquery())) or 0
    users = list(
        (await db.scalars(query.offset(params.offset).limit(params.limit))).all()
    )
    items = [
        AdminUserResponse(
            id=user.public_id,
            email=user.email,
            full_name=user.full_name,
            roles=sorted(await load_roles(db, user.id), key=lambda role: role.value),
            university_id=user.university_public_id,
            faculty_id=user.faculty_public_id,
            year_of_study=user.year_of_study,
            is_active=user.is_active,
            created_at=user.created_at,
        )
        for user in users
    ]
    await record_audit(
        db,
        actor_id=actor_id,
        action="admin.users.list",
        target_type="user",
        context={"limit": params.limit, "offset": params.offset},
    )
    return AdminUserPage(
        items=items, total=total, limit=params.limit, offset=params.offset
    )


async def list_audit_events(
    db: AsyncSession, params: PageParams
) -> AdminAuditEventPage:
    # No `selectinload` on the actor: the relationship is joined eagerly, so
    # asking for it again would be redundant rather than faster.
    query = select(AdminAuditEvent).order_by(
        AdminAuditEvent.created_at.desc(), AdminAuditEvent.id.desc()
    )
    total = await db.scalar(select(func.count()).select_from(query.subquery())) or 0
    events = list(
        (await db.scalars(query.offset(params.offset).limit(params.limit))).all()
    )
    return AdminAuditEventPage(
        items=[_audit_response(event) for event in events],
        total=total,
        limit=params.limit,
        offset=params.offset,
    )


async def list_competencies(
    db: AsyncSession, actor_id: uuid.UUID, params: AdminCompetencyPageParams
) -> AdminCompetencyPage:
    query = (
        select(Competency)
        .join(Competency.user)
        .options(
            selectinload(Competency.user),
            selectinload(Competency.course_unit)
            .selectinload(CourseUnit.university)
            .selectinload(University.grading_scale),
            selectinload(Competency.grade),
        )
        .order_by(Competency.created_at.desc(), Competency.id.desc())
    )
    if params.status is not None:
        query = query.where(Competency.status == params.status)
    total = await db.scalar(select(func.count()).select_from(query.subquery())) or 0
    rows = list(
        (await db.scalars(query.offset(params.offset).limit(params.limit))).all()
    )
    await record_audit(
        db,
        actor_id=actor_id,
        action="admin.competencies.list",
        target_type="competency",
        context={
            "limit": params.limit,
            "offset": params.offset,
            # The filter is recorded because a filtered read is a different
            # read: an auditor asking "what was pending on Tuesday" needs to be
            # able to see that the operator was looking at exactly that.
            "status": params.status.value if params.status is not None else None,
        },
    )
    return AdminCompetencyPage(
        items=[_competency_response(row) for row in rows],
        total=total,
        limit=params.limit,
        offset=params.offset,
    )


async def review_competency(
    db: AsyncSession,
    actor_id: uuid.UUID,
    competency_id: uuid.UUID,
    payload: AdminCompetencyReviewRequest,
) -> AdminCompetencyResponse:
    row = await db.scalar(
        select(Competency)
        .where(Competency.public_id == competency_id)
        .options(
            selectinload(Competency.user),
            selectinload(Competency.course_unit)
            .selectinload(CourseUnit.university)
            .selectinload(University.grading_scale),
            selectinload(Competency.grade),
        )
    )
    if row is None:
        raise NotFoundProblem("That competency record could not be found.")
    if payload.status is CompetencyStatus.PENDING:
        raise ValidationProblem(
            "An admin review must verify or reject the competency.",
            errors={"status": "pending is not a review decision"},
        )
    if payload.status is CompetencyStatus.REJECTED and not (
        payload.rejection_reason and payload.rejection_reason.strip()
    ):
        raise ValidationProblem(
            "A rejection reason is required.",
            errors={"rejection_reason": "required when rejecting"},
        )
    if payload.status is CompetencyStatus.VERIFIED:
        # MUST invariant 2: a tutor is competent in a unit on a B+ or higher. That
        # is a property of the record, not a judgement the console is trusted to
        # make -- the submission path enforces it, and without this check an
        # operator could verify a B or a D by hand and the two paths would
        # disagree about what "verified" means. Matching re-checks eligibility
        # separately, so this is the audit trail being right, not the only guard.
        scale = row.course_unit.university.grading_scale
        if scale is None:
            raise ValidationProblem(
                "This university has no configured competency threshold, "
                "so the competency cannot be verified.",
                errors={"status": "grading scale is not configured"},
            )
        minimum_points = scale.competency_min_points
        if row.grade.grade_points < minimum_points:
            raise ValidationProblem(
                "This grade is below the competency threshold for the university, "
                "so it cannot be verified. Reject it with a reason, or ask the "
                "tutor to submit a qualifying grade.",
                errors={
                    "status": (
                        f"requires {minimum_points} or higher on the {scale.name} scale"
                    )
                },
            )
    row.reviewed_by_id = actor_id
    row.status = payload.status
    row.rejection_reason = (
        payload.rejection_reason
        if payload.status is CompetencyStatus.REJECTED
        else None
    )
    row.verified_at = (
        datetime.now(UTC) if payload.status is CompetencyStatus.VERIFIED else None
    )
    if payload.status is CompetencyStatus.VERIFIED:
        from app.models.enums import UserRole
        from app.models.user import set_roles

        roles = set(await load_roles(db, row.user_id))
        roles.add(UserRole.TUTOR)
        await set_roles(db, row.user_id, roles)
        profile = await db.scalar(
            select(TutorProfile).where(TutorProfile.user_id == row.user_id)
        )
        if profile is None:
            db.add(TutorProfile(user_id=row.user_id))
    await db.flush()
    await record_audit(
        db,
        actor_id=actor_id,
        action=f"admin.competencies.{payload.status.value}",
        target_type="competency",
        target_public_id=row.public_id,
        context={"reason_provided": bool(payload.rejection_reason)},
    )
    return _competency_response(row)


async def list_tutor_standings(
    db: AsyncSession, actor_id: uuid.UUID, params: PageParams
) -> AdminTutorStandingPage:
    query = (
        select(TutorProfile)
        .join(TutorProfile.user)
        .options(selectinload(TutorProfile.user))
        .order_by(TutorProfile.created_at.desc(), TutorProfile.id.desc())
    )
    rows = list(
        (await db.scalars(query.offset(params.offset).limit(params.limit))).all()
    )
    await record_audit(
        db,
        actor_id=actor_id,
        action="admin.tutor_standings.list",
        target_type="tutor",
        context={"limit": params.limit, "offset": params.offset},
    )
    items = [
        AdminTutorStandingResponse(
            user_id=row.user.public_id,
            user_email=row.user.email,
            user_name=row.user.full_name,
            standing=row.standing,
            completed_sessions=row.completed_sessions,
            rating_count=row.rating_count,
            average_rating=(
                str(row.average_rating) if row.average_rating is not None else None
            ),
        )
        for row in rows
    ]
    return AdminTutorStandingPage(
        items=items,
        total=await db.scalar(select(func.count()).select_from(TutorProfile)) or 0,
        limit=params.limit,
        offset=params.offset,
    )


def _competency_response(row: Competency) -> AdminCompetencyResponse:
    # The gate is read here, not recomputed by the client, so the number an
    # operator is shown is the same one [review_competency] enforces.
    scale = row.course_unit.university.grading_scale
    minimum_points = None if scale is None else Decimal(scale.competency_min_points)
    return AdminCompetencyResponse(
        id=row.public_id,
        user_id=row.user.public_id,
        user_email=row.user.email,
        user_name=row.user.full_name,
        course_unit_id=row.course_unit.public_id,
        course_unit_code=row.course_unit.code,
        course_unit_name=row.course_unit.name,
        grade_label=row.grade.label,
        grade_points=str(Decimal(row.grade.grade_points)),
        competency_min_points=None if minimum_points is None else str(minimum_points),
        # No scale means no bar to clear. Reported as not meeting it rather than
        # optimistically as meeting it: [review_competency] refuses to verify
        # without a scale, so `true` here would be a claim the server will not
        # honour.
        meets_threshold=(
            False
            if minimum_points is None
            else row.grade.grade_points >= minimum_points
        ),
        status=row.status,
        source=row.source,
        evidence_reference=row.evidence_reference,
        rejection_reason=row.rejection_reason,
        created_at=row.created_at,
        verified_at=row.verified_at,
    )


def _audit_response(event: AdminAuditEvent) -> AdminAuditEventResponse:
    return AdminAuditEventResponse(
        id=event.public_id,
        actor_id=event.actor.public_id,
        actor_email=event.actor.email,
        actor_name=event.actor.full_name,
        action=event.action,
        target_type=event.target_type,
        target_public_id=event.target_public_id,
        context=event.context,
        created_at=event.created_at,
    )


async def record_audit(
    db: AsyncSession,
    *,
    actor_id: uuid.UUID,
    action: str,
    target_type: str,
    target_public_id: uuid.UUID | None = None,
    context: dict[str, object] | None = None,
) -> None:
    """Record only allowlisted metadata and leave commit ownership to the route."""
    db.add(
        AdminAuditEvent(
            actor_id=actor_id,
            action=action,
            target_type=target_type,
            target_public_id=target_public_id,
            context=context or {},
        )
    )
