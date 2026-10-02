"""Tutoring session scheduling and logging routes."""

import uuid

from fastapi import APIRouter, status

from app.api.deps import CurrentUser, DatabaseSession
from app.schemas.session import (
    SessionCreate,
    SessionPinResponse,
    SessionResponse,
    SessionTransitionRequest,
    VerifyPinRequest,
)
from app.services import session_service

router = APIRouter(prefix="/sessions", tags=["sessions"])


@router.post(
    "",
    response_model=SessionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create an accepted tutoring session",
)
async def create_session(
    payload: SessionCreate,
    caller: CurrentUser,
    db: DatabaseSession,
) -> SessionResponse:
    """Accept a matched request and create the live tutoring session."""
    return await session_service.create_session(db, caller.user, payload)


@router.get(
    "/me",
    response_model=list[SessionResponse],
    summary="My sessions",
)
async def list_sessions(
    caller: CurrentUser,
    db: DatabaseSession,
) -> list[SessionResponse]:
    """Every session the current user is part of."""
    return await session_service.list_sessions(db, caller.user)


@router.get(
    "/{session_id}",
    response_model=SessionResponse,
    summary="Load one session",
)
async def get_session(
    session_id: uuid.UUID,
    caller: CurrentUser,
    db: DatabaseSession,
) -> SessionResponse:
    """Fetch a specific session that belongs to the caller."""
    return await session_service.get_session(db, caller.user, session_id)


@router.post(
    "/{session_id}/transition",
    response_model=SessionResponse,
    summary="Move the session through its lifecycle",
)
async def transition_session(
    session_id: uuid.UUID,
    payload: SessionTransitionRequest,
    caller: CurrentUser,
    db: DatabaseSession,
) -> SessionResponse:
    """Advance or cancel a session, with server-side validation controls."""
    return await session_service.transition_session(
        db,
        caller.user,
        session_id,
        payload,
    )


@router.post(
    "/{session_id}/verify-pin",
    response_model=SessionResponse,
    summary="Verify the two-digit session handshake pin",
)
async def verify_session_pin(
    session_id: uuid.UUID,
    payload: VerifyPinRequest,
    caller: CurrentUser,
    db: DatabaseSession,
) -> SessionResponse:
    """Server-side handshake: the tutor reveals the pin; the tutee enters it."""
    return await session_service.verify_session_pin(
        db, caller.user, session_id, payload.pin
    )


@router.get(
    "/{session_id}/pin",
    response_model=SessionPinResponse,
    summary="Read the handshake pin (tutor only)",
)
async def reveal_session_pin(
    session_id: uuid.UUID,
    caller: CurrentUser,
    db: DatabaseSession,
) -> SessionPinResponse:
    """The tutor's half of the handshake: the digits to read out.

    Separate from `GET /{session_id}` so the PIN is not part of a payload both
    parties can fetch. The tutee asking here gets a 403: if they could read their
    own PIN the handshake would prove nothing.
    """
    return await session_service.reveal_session_pin(db, caller.user, session_id)
