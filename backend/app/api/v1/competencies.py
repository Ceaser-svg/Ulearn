"""Tutor competence validation routes."""

import uuid

from fastapi import APIRouter, status

from app.api.deps import CurrentUser, DatabaseSession
from app.schemas.competency import CompetencyCreate, CompetencyResponse
from app.services import validation_service

router = APIRouter(prefix="/competencies", tags=["competencies"])


@router.get("/me", response_model=list[CompetencyResponse], summary="My competencies")
async def list_my_competencies(
    caller: CurrentUser,
    db: DatabaseSession,
) -> list[CompetencyResponse]:
    """Every submitted proof for the signed-in tutor."""
    return await validation_service.list_competencies(db, caller.user)


@router.post(
    "",
    response_model=CompetencyResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Submit tutor validation evidence",
)
async def create_competency(
    payload: CompetencyCreate,
    caller: CurrentUser,
    db: DatabaseSession,
) -> CompetencyResponse:
    """Submit a transcript or portfolio claim for a course unit."""
    return await validation_service.create_competency(db, caller.user, payload)


@router.get(
    "/{competency_id}",
    response_model=CompetencyResponse,
    summary="Fetch one competency",
)
async def get_competency(
    competency_id: uuid.UUID,
    caller: CurrentUser,
    db: DatabaseSession,
) -> CompetencyResponse:
    """A single competency record owned by the signed-in user."""
    return await validation_service.get_competency(db, caller.user, competency_id)
