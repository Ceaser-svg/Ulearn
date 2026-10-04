"""Authentication routes.

Every handler here is four lines: resolve the session, call the service, return
the schema. The rules live in `app.services.auth` and the problem documents are
built once in `app.main`, so there is exactly one place in the codebase where a
failure becomes a response body.
"""

from typing import Annotated

from fastapi import APIRouter, Body, Request, status

from app.api.deps import CurrentUser, DatabaseSession
from app.schemas.user import (
    AuthResponse,
    CurrentUserResponse,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
)
from app.services import auth_service, rate_limit

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post(
    "/register",
    response_model=AuthResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create an account",
)
async def register(
    payload: RegisterRequest, db: DatabaseSession, request: Request
) -> AuthResponse:
    """Register and receive a token pair.

    201 rather than 200 because a resource was created, and the response body is
    the new account alongside its first tokens -- one round trip, so the client
    never holds a valid token it cannot yet render a name for.

    Takes the `Request` only to learn who is calling: registration costs a full
    Argon2 hash, so the endpoint needs a per-address ceiling and the address is
    on the socket, not in the body.
    """
    return await auth_service.register(
        db, payload, client_address=rate_limit.client_ip(request)
    )


@router.post("/login", response_model=AuthResponse, summary="Sign in")
async def login(
    payload: LoginRequest, db: DatabaseSession, request: Request
) -> AuthResponse:
    """Exchange credentials for a token pair.

    A wrong password and an unknown address are the same 401 with the same body.
    That is deliberate; see `app.services.auth`.

    Takes the `Request` only to learn who is calling, for the same reason
    registration does. Wrong passwords are counted per account *and* per
    address, and the second of those is not in the body.
    """
    return await auth_service.authenticate(
        db, payload, client_address=rate_limit.client_ip(request)
    )


@router.post(
    "/refresh", response_model=AuthResponse, summary="Exchange a refresh token"
)
async def refresh(payload: RefreshRequest, db: DatabaseSession) -> AuthResponse:
    """Exchange a refresh token for a new pair.

    The client must replace its stored refresh token with the one in this
    response: the token it just sent stops working the moment this returns, and
    sending it a second time is treated as theft and kills the chain.
    """
    return await auth_service.refresh(db, payload.refresh_token)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, summary="Sign out")
async def logout(
    caller: CurrentUser,
    db: DatabaseSession,
    payload: Annotated[RefreshRequest | None, Body()] = None,
) -> None:
    """Revoke the caller's refresh token.

    204 whether or not a token was presented. Sign-out is what the student asked
    for, and refusing because the server had not heard of the token would leave
    someone unable to end a session on a device that lost its state.

    The body is optional rather than required so that a client which has already
    cleared its token store can still sign out cleanly.
    """
    await auth_service.sign_out(
        db, caller.user, payload.refresh_token if payload is not None else None
    )


@router.get("/me", response_model=CurrentUserResponse, summary="The signed-in user")
async def read_current_user(
    caller: CurrentUser, db: DatabaseSession
) -> CurrentUserResponse:
    """The caller's own record, including the consent timestamp.

    The only endpoint that returns it. `UserResponse` deliberately has no
    consent field, so no other route can leak it by accident.
    """
    return await auth_service.load_current_user(db, caller.user)
