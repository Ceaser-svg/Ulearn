"""Authenticated routes for the separate MUST admin application."""

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import AdminUser, DatabaseSession
from app.schemas.admin import (
    AdminAuditEventPage,
    AdminCompetencyPage,
    AdminCompetencyPageParams,
    AdminCompetencyResponse,
    AdminCompetencyReviewRequest,
    AdminTutorStandingPage,
    AdminUserPage,
)
from app.schemas.common import PageParams
from app.services import admin_service

router = APIRouter(prefix="/admin", tags=["admin"])
AdminPageParams = Annotated[PageParams, Depends()]
CompetencyPageParams = Annotated[AdminCompetencyPageParams, Depends()]


@router.get("/users", response_model=AdminUserPage)
async def list_users(
    caller: AdminUser,
    db: DatabaseSession,
    params: AdminPageParams,
) -> AdminUserPage:
    """List pilot users with the minimum fields staff need to operate."""
    page = await admin_service.list_users(db, caller.user.id, params)
    await db.commit()
    return page


@router.get("/audit-events", response_model=AdminAuditEventPage)
async def list_audit_events(
    _caller: AdminUser,
    db: DatabaseSession,
    params: AdminPageParams,
) -> AdminAuditEventPage:
    """Read the append-only privileged-action log."""
    return await admin_service.list_audit_events(db, params)


@router.get("/competencies", response_model=AdminCompetencyPage)
async def list_competencies(
    caller: AdminUser,
    db: DatabaseSession,
    params: CompetencyPageParams,
) -> AdminCompetencyPage:
    """List the review queue, optionally narrowed to one status.

    Each row carries its grade label, the bar that grade has to clear, and
    whether it clears it, so an operator can see a refusal before making the
    decision that would be refused.
    """
    page = await admin_service.list_competencies(db, caller.user.id, params)
    await db.commit()
    return page


@router.patch(
    "/competencies/{competency_id}/review",
    response_model=AdminCompetencyResponse,
)
async def review_competency(
    competency_id: uuid.UUID,
    payload: AdminCompetencyReviewRequest,
    caller: AdminUser,
    db: DatabaseSession,
) -> AdminCompetencyResponse:
    response = await admin_service.review_competency(
        db, caller.user.id, competency_id, payload
    )
    await db.commit()
    return response


@router.get("/tutor-standings", response_model=AdminTutorStandingPage)
async def list_tutor_standings(
    caller: AdminUser,
    db: DatabaseSession,
    params: AdminPageParams,
) -> AdminTutorStandingPage:
    page = await admin_service.list_tutor_standings(db, caller.user.id, params)
    await db.commit()
    return page
