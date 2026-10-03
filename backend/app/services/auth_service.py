"""Authentication: registration, sign-in, refresh rotation, and sign-out.

This is the first module in `app.services` to hold real logic, so it sets the
pattern for the others. The rules it exists to enforce, and where each comes
from, are in `docs/architecture.md` section 9. The short version:

- A password is checked against a stored Argon2id hash, and a sign-in for an
  unknown email spends the same Argon2 work as one for a wrong password, so the
  endpoint cannot be used to discover which addresses have accounts.
- Refresh tokens are opaque, stored only as a peppered HMAC, and rotated on
  every use. Presenting one that was already rotated is treated as theft and
  kills the chain.
- Every failure a caller can provoke is indistinguishable from every other
  failure a caller can provoke.

`app.core.security` provides the primitives. Nothing here re-implements one, and
nothing here decides a password policy -- `app.core.password_policy` owns that.
"""

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import Settings, get_settings
from app.core.exceptions import (
    AuthenticationProblem,
    ConflictProblem,
    NotFoundProblem,
    TooManyRequestsProblem,
    ValidationProblem,
)
from app.core.password_policy import denial_reason
from app.core.security import (
    TokenPair,
    burn_password_verification_async,
    create_token_pair,
    hash_opaque_token,
    hash_password_async,
    password_needs_rehash,
    verify_password_async,
)
from app.models.course_unit import Subject, University
from app.models.enums import UserRole
from app.models.user import RefreshToken, User, load_roles, set_roles
from app.schemas.user import (
    AuthResponse,
    CurrentUserResponse,
    LoginRequest,
    RegisterRequest,
    TokenResponse,
    UpdateProfileRequest,
)
from app.services import rate_limit

#: One message for every sign-in failure.
#:
#: "no such account", "wrong password", and "account deactivated" are three
#: different facts, and a client that can tell them apart can use the sign-in
#: form to test whether a given student has an account. The pilot's threat model
#: starts from a list of student email addresses, so that is the enumeration this
#: exists to stop.
#:
#: It is also why the *work* is uniform and not only the message: see
#: `burn_password_verification`.
_CREDENTIALS_REJECTED = "That email or password is not right."


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _as_utc(value: datetime) -> datetime:
    """A datetime read back from the database, made comparable to `_utcnow()`.

    PostgreSQL's `timestamptz` hands back an aware datetime, but SQLite stores no
    timezone at all and returns a naive one, so the same query yields different
    types depending on the backend. Comparing that naive value against an aware
    one raises `TypeError` rather than returning a wrong answer, which is the
    safer of the two failures -- but it turns the default test suite into a 500.

    A naive value is therefore read as UTC, which is what it was written as.
    Every timestamp in this schema is written by `_utcnow()`, so nothing here
    has to guess what zone a naive value meant.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def normalise_email(email: str) -> str:
    """The form an address is stored and compared in.

    Applied on registration *and* on sign-in. Normalising on only one side is
    how an account ends up reachable under one spelling and not another, which
    reads to the student as a service that has lost their password.
    """
    return email.strip().lower()


def _credentials_rejected() -> AuthenticationProblem:
    return AuthenticationProblem(_CREDENTIALS_REJECTED)


# --- issuing tokens --------------------------------------------------------


def _token_response(pair: TokenPair) -> TokenResponse:
    """The wire form of a freshly minted pair.

    `expires_in` is seconds because that is what a client needs to schedule its
    own refresh, while the setting is in minutes because that is how a human
    reads it in a deployment manifest. Converting here means the two spellings
    never disagree in two different files.
    """
    return TokenResponse(
        access_token=pair.access_token,
        refresh_token=pair.refresh_token,
        expires_in=get_settings().access_token_ttl * 60,
    )


def _record_refresh_token(db: AsyncSession, user: User, pair: TokenPair) -> None:
    """Persist the handle for an issued refresh token.

    Only `hash_opaque_token(pair.refresh_token)` is stored, so a stolen database
    yields no usable token. The row's own id is the handle the token's `jti`
    names, and it is the `replaced_by_id` link that lets a reuse kill the chain.
    """
    db.add(
        RefreshToken(
            id=pair.refresh_token_id,
            user_id=user.id,
            token_hash=hash_opaque_token(pair.refresh_token),
            expires_at=pair.refresh_expires_at,
        )
    )


async def _issue_tokens(db: AsyncSession, user: User) -> AuthResponse:
    """Mint a token pair for `user`, store the refresh handle, return both.

    Not committed. The caller commits once, at the end of whatever it was doing,
    so a token is never issued for a user whose other writes then fail.
    """
    pair = create_token_pair(subject=user.public_id)
    _record_refresh_token(db, user, pair)
    return AuthResponse(
        tokens=_token_response(pair),
        user=await _current_user(db, user),
    )


async def _current_user(db: AsyncSession, user: User) -> CurrentUserResponse:
    """The caller's own record, with its roles loaded.

    Roles come from the join table rather than the token, which is what lets a
    role change take effect on the next request instead of at the next refresh.

    They are injected after validation rather than passed into it: `User` has no
    `roles` attribute to read, so `model_validate` cannot source them. Pydantic
    v2 has no `update=` on `model_validate`; `model_copy` is the operation that
    does this, and it skips revalidation, which is safe here because the only
    value replaced is a set of enums read from our own column.
    """
    validated = CurrentUserResponse.model_validate(user)
    from app.models.user import load_primary_course_unit_public_ids

    return validated.model_copy(
        update={
            "roles": sorted(await load_roles(db, user.id)),
            "primary_course_unit_ids": await load_primary_course_unit_public_ids(
                db, user.id
            ),
        }
    )


async def load_current_user(db: AsyncSession, user: User) -> CurrentUserResponse:
    """The caller's own record, for `GET /auth/me`.

    Public where `_current_user` is not because it is the shape `GET /auth/me`
    returns, and that route is a reader rather than part of a token issuance.
    """
    return await _current_user(db, user)


# --- loading users ---------------------------------------------------------


def _user_query():
    """Users with the relationships the response schemas read.

    `university` and `faculty` are loaded because `CurrentUserResponse` reaches
    their public ids through the relationship, and a lazy load on an async
    session raises rather than quietly costing a query. Being explicit about it
    here is cheaper than debugging a `MissingGreenlet` under load.
    """
    return select(User).options(
        selectinload(User.university),
        selectinload(User.faculty),
    )


async def load_user_by_email(db: AsyncSession, email: str) -> User | None:
    """The account for `email`, or `None`.

    `None` is a first-class return rather than an exception because the caller
    cannot tell the difference anyway, and an exception would invite someone to
    branch on which one happened.
    """
    result = await db.execute(_user_query().where(User.email == normalise_email(email)))
    return result.scalar_one_or_none()


async def load_user_by_public_id(db: AsyncSession, public_id: uuid.UUID) -> User:
    """The account with this public id, or `NotFoundProblem`.

    A missing user and a deactivated one are the same answer here. An
    authenticated caller asking for an account that does not exist has a token
    that is somehow valid for it, which is worth a 404 rather than a 403 that
    would confirm the id is real.
    """
    result = await db.execute(_user_query().where(User.public_id == public_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise NotFoundProblem("That account could not be found.")
    return user


async def _load_user_by_id(db: AsyncSession, user_id: uuid.UUID) -> User | None:
    """The account with this primary key.

    Separate from `load_user_by_public_id` because the two take identifiers from
    different places: a public id arrives from a client and is untrusted, while
    a primary key here is read off a row this service already owns. A function
    that took either would be a function whose callers had to be trusted
    differently, which is a distinction worth more than the extra name.
    """
    result = await db.execute(_user_query().where(User.id == user_id))
    return result.scalar_one_or_none()


# --- registration ----------------------------------------------------------


async def register(
    db: AsyncSession, request: RegisterRequest, *, client_address: str
) -> AuthResponse:
    """Create an account and sign the new student straight in.

    The account starts with no name. Sign-up asks for an email and a password
    only, and the name arrives in the onboarding wizard; the user row allows a
    null name precisely so that a student who abandons the wizard still has a
    usable account rather than a half-built one that cannot sign in.

    Note the order of operations, which is a security property rather than a
    style choice. The password is hashed *before* the duplicate check runs, so
    both paths cost one Argon2 operation:

    - Looking up first and returning the 409 early would make registration as
      fast as a database read for an address that already has an account and as
      slow as 19 MiB of Argon2 for one that does not. That difference is
      measurable over a network, and this endpoint is the one place an attacker
      holding a list of student addresses gets to time a request per address.

    The throttle check comes before all of it, because that is what stops the
    endpoint being used to buy CPU: one accepted sign-up costs a full Argon2
    hash, so an unthrottled registration endpoint is a way to spend this
    instance's memory budget at will.
    """
    settings = get_settings()
    wait = await rate_limit.lock_remaining(
        db, rate_limit.SCOPE_REGISTER_IP, client_address
    )
    if wait:
        raise rate_limit.refuse(
            "Too many accounts created from this network. Try again later.",
            wait,
        )

    reason = denial_reason(request.password)
    if reason is not None:
        raise ValidationProblem(
            "That password cannot be accepted.", errors={"password": reason}
        )

    email = normalise_email(request.email)
    password_hash = await hash_password_async(request.password)

    if await load_user_by_email(db, email) is not None:
        await _charge_registration(db, client_address, settings)
        await db.commit()
        raise ConflictProblem("An account already exists for that email address.")

    user = User(email=email, full_name=None, password_hash=password_hash)
    db.add(user)
    try:
        # The unique index is the authority on duplicates. The check above is
        # there to give the common case a clear message; this is what makes a
        # race between two simultaneous sign-ups lose safely rather than raise
        # an IntegrityError out of a request handler.
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        await _charge_registration(db, client_address, settings)
        await db.commit()
        raise ConflictProblem(
            "An account already exists for that email address."
        ) from exc

    # Every account starts as a tutee. The tutor role is not grantable here: it
    # is earned by declaring a grade and having that competency verified, which
    # is what the provisional-to-verified path is for.
    await set_roles(db, user.id, {UserRole.STUDENT})

    await _charge_registration(db, client_address, settings)

    response = await _issue_tokens(db, user)
    await db.commit()
    return response


async def _charge_registration(
    db: AsyncSession, client_address: str, settings: Settings
) -> None:
    """Charge one registration attempt against the per-address budget.

    Charged whether the account was created or refused as a duplicate, because
    both have already cost a full Argon2 hash by the time this is reached, and
    bounding that cost is the entire point of the counter. Charging only
    successes — which is what this did at first — leaves the endpoint with an
    unbounded hashing budget for anyone willing to send addresses that already
    exist, which is precisely what an attacker probing for student accounts
    does: every probe returns 409, so it identifies real accounts *and* buys
    unlimited CPU, while never being charged for it.

    A rejection that happens before the hash is not charged, because it costs
    nothing: a weak password, or a caller already throttled.
    """
    await rate_limit.record_attempt(
        db,
        rate_limit.SCOPE_REGISTER_IP,
        client_address,
        max_attempts=settings.auth_register_ip_max_attempts,
        lockout=timedelta(seconds=settings.auth_register_ip_lockout_seconds),
    )


# --- sign-in ---------------------------------------------------------------


async def authenticate(
    db: AsyncSession, request: LoginRequest, *, client_address: str
) -> AuthResponse:
    """Exchange credentials for a token pair.

    Every credentials rejection below is the same exception with the same
    message, and each one costs the same Argon2 work:

    - No such user: `burn_password_verification` runs a verification against a
      decoy hash, so this path takes as long as a wrong password.
    - Wrong password: the stored hash is well-formed, so Argon2 has already been
      paid for by the time it returns.
    - Deactivated account: verified first, so this path is the wrong-password
      path. A student locked out for a policy reason learns nothing they could
      not already learn by guessing.

    The rate-limit checks run *before* the Argon2 work, which is the whole point
    of having them: a throttled address costs a database read rather than 19 MiB
    of hashing, so the limiter is a CPU saving as much as a security control.

    The order of the two checks is deliberate. The address is checked first
    because it is the ceiling that bounds *this* caller regardless of which
    account they name, and checking it first means a spraying attack is stopped
    before it can create a lockout artifact on a hundred innocent accounts.
    """
    email = normalise_email(request.email)

    address_wait = await rate_limit.lock_remaining(
        db, rate_limit.SCOPE_LOGIN_IP, client_address
    )
    if address_wait:
        raise _throttled(address_wait)

    account_wait = await rate_limit.lock_remaining(
        db, rate_limit.SCOPE_LOGIN_ACCOUNT, email
    )
    if account_wait:
        raise _throttled(account_wait)

    user = await load_user_by_email(db, email)
    if user is None:
        await burn_password_verification_async()
        await _count_failure(db, client_address, email)
        raise _credentials_rejected()

    if not await verify_password_async(request.password, user.password_hash):
        await _count_failure(db, client_address, email)
        raise _credentials_rejected()

    if not user.is_active:
        # Verified, and still refused, so the time spent is the same as a wrong
        # password and the response is the same as a wrong password.
        raise _credentials_rejected()

    if user.is_deleted:
        # Unreachable in practice: deletion rewrites the address, so a tombstone
        # cannot be reached by the one a student types. Stated anyway, because
        # this is the path that would hand back a token pair if that ever
        # stopped being true, and because it costs a comparison.
        raise _credentials_rejected()

    if password_needs_rehash(user.password_hash):
        # The password was correct, so this is the one moment rewriting the
        # stored hash is safe. It is how a raised Argon2 cost reaches existing
        # accounts without a migration: each account is upgraded the next time
        # its owner signs in.
        user.password_hash = await hash_password_async(request.password)

    # A student who fat-fingers their password twice and then remembers it must
    # not carry those two failures forward, so the account counter is cleared
    # here. The address counter deliberately is not: see `app.services.rate_limit`.
    await rate_limit.reset(db, rate_limit.SCOPE_LOGIN_ACCOUNT, email)

    response = await _issue_tokens(db, user)
    await db.commit()
    return response


def _throttled(retry_after_seconds: int) -> TooManyRequestsProblem:
    return rate_limit.refuse(
        "Too many sign-in attempts. Wait before trying again.",
        retry_after_seconds,
    )


async def _count_failure(db: AsyncSession, client_address: str, email: str) -> None:
    """Charge one failed sign-in to both counters, and persist that.

    The address counter is charged whether or not the address has an account.
    An attacker guessing against addresses that do not exist is still an attacker
    spending CPU on this service, and the decoy burn above makes each attempt
    cost the same either way.

    Committed here rather than left to the caller's error path, which raises
    immediately afterwards. `get_db` rolls back on an unhandled exception, so an
    uncommitted counter is discarded on exactly the attempts that were meant to
    count.
    """
    settings = get_settings()
    await rate_limit.record_attempt(
        db,
        rate_limit.SCOPE_LOGIN_ACCOUNT,
        email,
        max_attempts=settings.auth_login_max_attempts,
        lockout=timedelta(seconds=settings.auth_login_lockout_seconds),
    )
    await rate_limit.record_attempt(
        db,
        rate_limit.SCOPE_LOGIN_IP,
        client_address,
        max_attempts=settings.auth_login_ip_max_attempts,
        lockout=timedelta(seconds=settings.auth_login_ip_lockout_seconds),
    )
    await db.commit()


# --- refresh ---------------------------------------------------------------

#: Ceiling on the chain walk in `_revoke_terminated_chain`.
#:
#: Not a security control. `replaced_by_id` is written once per rotation and
#: always points at a newer row, so a cycle is not constructible; this is here so
#: that a corrupted link is a bounded error rather than a hang.
_MAX_CHAIN_LENGTH = 256


async def _revoke_terminated_chain(db: AsyncSession, reused: RefreshToken) -> None:
    """Revoke a replayed token and every token descended from it.

    Reuse of a rotated token means either the attacker or the student is holding
    a token that should be dead, and nothing in the request can say which. So
    the descendants die too: whoever is legitimate, the next refresh fails and
    the student signs in again.

    The walk follows `replaced_by_id` forward rather than revoking every active
    token the user holds. That distinction matters: a student signed in on a
    phone and a laptop has two independent chains, and the honest response to a
    stolen token revokes the compromised chain rather than also signing the
    student out of the device that was never touched.
    """
    now = _utcnow()
    current: RefreshToken | None = reused
    for _ in range(_MAX_CHAIN_LENGTH):
        if current is None:
            return
        if current.revoked_at is None:
            current.revoked_at = now
        if current.replaced_by_id is None:
            return
        result = await db.execute(
            select(RefreshToken).where(RefreshToken.id == current.replaced_by_id)
        )
        current = result.scalar_one_or_none()


async def refresh(db: AsyncSession, refresh_token: str) -> AuthResponse:
    """Exchange a refresh token for a new pair, rotating the old one.

    Rotation is per RFC 9700. The client is expected to replace its stored
    refresh token on every call, because the one it just used stops working the
    moment this returns.
    """
    token_hash = hash_opaque_token(refresh_token)
    result = await db.execute(
        select(RefreshToken).where(RefreshToken.token_hash == token_hash)
    )
    stored = result.scalar_one_or_none()

    if stored is None:
        # Either a forged token or one whose pepper has been rotated away. Both
        # are the same answer, and neither is worth distinguishing.
        raise _credentials_rejected()

    if stored.revoked_at is not None:
        # A rotated token came back. That is the theft signal.
        await _revoke_terminated_chain(db, stored)
        await db.commit()
        raise _credentials_rejected()

    if _as_utc(stored.expires_at) <= _utcnow():
        raise _credentials_rejected()

    user = await _load_user_by_id(db, stored.user_id)
    # The cascade deletes a user's tokens with the user, so a token row that
    # outlived its owner means a corrupted database rather than a state worth
    # handling. It is still refused rather than crashing the request.
    if user is None or not user.is_active:
        raise _credentials_rejected()

    if user.is_deleted:
        # A tombstone has every refresh token revoked, so `stored.is_revoked`
        # above already refuses it. Repeated because this is the longest-lived
        # credential in the system and the one a stolen token would be replayed
        # through first: the check is a comparison, and the failure mode of
        # omitting it is a deleted account minting 30-day sessions.
        raise _credentials_rejected()

    pair = create_token_pair(subject=user.public_id)
    _record_refresh_token(db, user, pair)

    # Retire the presented token and point it at its replacement. The link is
    # what makes the next reuse of *this* token walk into the live one.
    await db.flush()
    stored.revoked_at = _utcnow()
    stored.replaced_by_id = pair.refresh_token_id

    response = AuthResponse(
        tokens=_token_response(pair),
        user=await _current_user(db, user),
    )
    await db.commit()
    return response


# --- sign-out --------------------------------------------------------------


async def sign_out(db: AsyncSession, user: User, refresh_token: str | None) -> None:
    """Revoke the presented refresh token.

    Revoking rather than deleting keeps the chain walkable, so a token replayed
    after sign-out is still recognised as revoked rather than as an unknown
    token. The two produce the same response either way; keeping the row is what
    lets a later reuse kill the right chain.

    A missing or unknown token is not an error. Signing out is what the student
    asked for, and refusing because the server had not heard of the token would
    leave them unable to end a session on a device that lost its state.
    """
    if refresh_token is None:
        return
    result = await db.execute(
        select(RefreshToken).where(
            RefreshToken.token_hash == hash_opaque_token(refresh_token)
        )
    )
    stored = result.scalar_one_or_none()
    if stored is None or stored.user_id != user.id:
        return
    if stored.revoked_at is None:
        stored.revoked_at = _utcnow()
    await db.commit()


# --- profile ---------------------------------------------------------------


async def update_profile(
    db: AsyncSession, user: User, request: UpdateProfileRequest
) -> CurrentUserResponse:
    """Apply the wizard's step to the caller's own profile.

    Only the fields the client actually sent are touched. The wizard saves one
    step at a time, so a step carrying only `full_name` must not blank the
    faculty the student picked on the previous screen, and a retried step has to
    be safe to send twice.

    Consent is deliberately one-way. `academic_data_consented` records the grant;
    there is no way to unset the timestamp here, because withdrawing consent
    under the Uganda Data Protection and Privacy Act has to be as express as the
    grant was and has to be retained as evidence, which is a different operation
    from editing a profile field.
    """
    sent = request.model_dump(exclude_unset=True)

    if "university_id" in sent:
        previous_university = user.university_id
        user.university_id = await _resolve_university(db, sent["university_id"])
        if user.university_id != previous_university:
            user.faculty_id = None
    if "faculty_id" in sent:
        faculty_university = user.university_id
        user.faculty_id = await _resolve_subject(
            db,
            sent["faculty_id"],
            university_id=faculty_university,
        )
    if "year_of_study" in sent:
        user.year_of_study = sent["year_of_study"]
    if "full_name" in sent:
        user.full_name = sent["full_name"]
    if sent.get("academic_data_consented") and user.academic_data_consented_at is None:
        user.academic_data_consented_at = _utcnow()

    if "primary_course_unit_ids" in sent:
        from app.models.user import set_primary_course_units

        internal_ids = await _resolve_course_units(db, sent["primary_course_unit_ids"])
        await set_primary_course_units(db, user.id, internal_ids)

    await db.commit()
    # The relationships are stale after writing to the foreign keys, and a
    # lazy load would raise on an async session, so they are refreshed from the
    # database rather than read off the instance.
    return await _current_user(db, await load_user_by_public_id(db, user.public_id))


async def _resolve_university(
    db: AsyncSession, public_id: uuid.UUID | None
) -> uuid.UUID | None:
    """The primary key for a public id, or `NotFoundProblem`.

    A client that sends an invented id is not a client with a stale cache, so
    this is a 404 rather than a silently ignored field: writing NULL because the
    id was unrecognised would look to the student like they had no university.
    """
    if public_id is None:
        return None
    result = await db.execute(
        select(University.id).where(University.public_id == public_id)
    )
    row = result.scalar_one_or_none()
    if row is None:
        raise NotFoundProblem("That university could not be found.")
    return row


async def _resolve_subject(
    db: AsyncSession,
    public_id: uuid.UUID | None,
    *,
    university_id: uuid.UUID | None = None,
) -> uuid.UUID | None:
    """The primary key for a faculty's public id, or `NotFoundProblem`."""
    if public_id is None:
        return None
    result = await db.execute(
        select(Subject.id).where(
            Subject.public_id == public_id,
            Subject.university_id == university_id,
        )
    )
    row = result.scalar_one_or_none()
    if row is None:
        raise NotFoundProblem("That faculty could not be found.")
    return row


async def _resolve_course_units(
    db: AsyncSession, public_ids: list[uuid.UUID] | None
) -> list[uuid.UUID]:
    """The primary keys for the course units."""
    if not public_ids:
        return []
    from app.models.course_unit import CourseUnit

    result = await db.execute(
        select(CourseUnit.id).where(CourseUnit.public_id.in_(public_ids))
    )
    rows = list(result.scalars())
    if len(rows) != len(public_ids):
        raise NotFoundProblem("One or more course units could not be found.")
    return rows


__all__ = [
    "authenticate",
    "load_user_by_email",
    "load_user_by_public_id",
    "normalise_email",
    "refresh",
    "register",
    "sign_out",
    "update_profile",
]
