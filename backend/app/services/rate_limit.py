"""Rate limiting for sign-in and sign-up.

Two independent ceilings, because they answer different questions:

- **Per account**, keyed by normalised email address. Stops one account being
  ground down by a focused guessing run.
- **Per client address**, keyed by IP. Stops the run itself: one address
  spraying a thousand addresses, which the per-account ceiling does not slow
  down at all, since every one of those accounts has zero failures against it.

Neither alone is sufficient, and the reason is worth being explicit about. The
per-account limit is trivially evaded by using each address once. The per-IP
limit is evaded by a distributed source, which for a student network means
"anywhere with a VPN", but it costs the attacker real infrastructure and it is
what stops the cheap version of the attack. Both are cheap to run, so both are
run.

Two properties that are load-bearing and easy to lose:

**The increment is atomic.** A read-modify-write loses counts under concurrency,
and an attacker parallelises requests for exactly that reason: twenty wrong
passwords sent at once must count as twenty, not as one. Measured on this
project's SQLite configuration, twenty concurrent read-modify-write increments
of a counter starting at zero leave it at one. A limiter written the obvious way
would let an attacker who is patient enough to batch get twenty tries per batch
forever. So the increment is a single `INSERT ... ON CONFLICT DO UPDATE ...
RETURNING`, which both supported engines execute atomically.

**A successful sign-in resets the account counter but not the IP counter.**
Resetting the account counter on success is what stops a student who fat-fingers
their password twice from being punished for it. Resetting the IP counter on
success would hand an attacker holding one valid account a way to mint an
unlimited attempt budget, since they can sign in before every guessing run. The
IP counter therefore only ever falls when a lock expires.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import case, select, update
from sqlalchemy.dialects.postgresql import insert as postgresql_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import TooManyRequestsProblem
from app.core.security import new_uuid7
from app.models.rate_limit import RateLimitCounter

#: Wrong passwords against one account.
SCOPE_LOGIN_ACCOUNT = "auth.login.account"

#: Wrong passwords from one client address, across all accounts.
SCOPE_LOGIN_IP = "auth.login.ip"

#: Accepted sign-ups from one client address.
SCOPE_REGISTER_IP = "auth.register.ip"

#: Stand-in key when the transport gave us no client address at all.
#:
#: Deliberately a fixed string rather than a rejection. A 500 because a socket
#: had no peer address would be a self-inflicted outage, and grouping these
#: requests together merely makes the limiter stricter than configured for a
#: transport that should not occur in the first place.
UNKNOWN_CLIENT = "unknown"


def _utc(value: datetime) -> datetime:
    """Normalize to UTC so SQLite and PostgreSQL agree on the same instant."""
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def _utcnow() -> datetime:
    return _utc(datetime.now(UTC))


def client_ip(request) -> str:
    """The address to rate limit this request against.

    `X-Forwarded-For` is only consulted when `trusted_proxy_hops` says a proxy
    really is in front of this process, and then only the entry that many hops
    from the right. Both halves matter:

    - Trusting the header without a proxy to vouch for it means an attacker
      chooses their own rate-limit identity by setting a header, which makes the
      per-IP ceiling decorative.
    - Taking the *leftmost* entry rather than the rightmost means an attacker
      appends a fake address to whatever the proxy already set and is believed.
      The rightmost entry is the one the closest trusted proxy wrote.

    Count the hops exactly. Too few and every request shares the proxy's address,
    so one student's five wrong passwords lock out a campus; too many and an
    attacker can prepend forged entries.
    """
    hops = get_settings().trusted_proxy_hops

    if hops > 0:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            chain = [entry.strip() for entry in forwarded.split(",") if entry.strip()]
            if len(chain) >= hops:
                return chain[-hops]

    peer = request.client
    if peer is not None and peer.host:
        return peer.host

    return UNKNOWN_CLIENT


def _counter_insert(db: AsyncSession):
    """An `INSERT` carrying this dialect's `ON CONFLICT DO UPDATE`.

    The two dialects agree on the Python-level API -- same `index_elements`,
    same `set_`, same `returning` -- and disagree only on the compiled SQL, so
    the statement itself is shared and only the entry point is chosen.

    An unrecognised dialect raises rather than falling back to a
    read-modify-write. A silent fallback would look correct and undercount under
    concurrency, which is precisely the bug this module exists to not have.
    """
    dialect = db.get_bind().dialect.name
    if dialect == "postgresql":
        return postgresql_insert(RateLimitCounter)
    if dialect == "sqlite":
        return sqlite_insert(RateLimitCounter)
    raise RuntimeError(
        f"rate limiting needs an atomic upsert, which is implemented for "
        f"postgresql and sqlite only; this connection is {dialect!r}"
    )


@dataclass(frozen=True, slots=True)
class AttemptOutcome:
    """What a failure did to a counter."""

    attempts: int
    locked: bool
    retry_after_seconds: int


async def lock_remaining(db: AsyncSession, scope: str, key: str) -> int:
    """Seconds until this caller may try again, or 0 if they may try now.

    A read with no lock and no side effects, so it is safe to call at the top of
    a request to decide whether to do any expensive work at all.
    """
    result = await db.execute(
        select(RateLimitCounter.locked_until).where(
            RateLimitCounter.scope == scope,
            RateLimitCounter.key == key,
        )
    )
    locked_until = result.scalar_one_or_none()
    if locked_until is None:
        return 0
    remaining = (_utc(locked_until) - _utcnow()).total_seconds()
    return int(remaining) + 1 if remaining > 0 else 0


async def _clear_expired_lock(db: AsyncSession, scope: str, key: str) -> None:
    """Zero a counter whose cooldown has run out.

    Conditional in the `WHERE` rather than read-then-write, so it is idempotent
    and two requests waking at the same instant cannot undo each other. It is
    still a separate statement from the increment that follows, which costs a
    little precision: two failures arriving in the same instant as the expiry
    could land on 1 rather than 2. That is not a bypass -- the attacker is no
    better off than a single failure, and the counter is exact again from the
    next request on.
    """
    now = _utcnow()
    await db.execute(
        update(RateLimitCounter)
        .where(
            RateLimitCounter.scope == scope,
            RateLimitCounter.key == key,
            RateLimitCounter.locked_until.is_not(None),
            RateLimitCounter.locked_until <= now,
        )
        .values(attempts=0, locked_until=None, updated_at=now)
    )


async def record_attempt(
    db: AsyncSession,
    scope: str,
    key: str,
    *,
    max_attempts: int,
    lockout: timedelta,
) -> AttemptOutcome:
    """Charge one attempt against a scope's budget, and lock once it is spent.

    Not every scope charges every attempt. The two sign-in scopes charge only
    failures, because a successful sign-in is not something to ration. The
    registration scope charges *every attempt that reaches the password hash*,
    successful or not, because that hash is the cost being bounded: a duplicate
    probe costs exactly as much CPU as a real sign-up and would otherwise be a
    way to buy unbounded hashing. What it does not charge is a rejection that
    happens before the hash — a weak password, or a caller already throttled —
    because those cost nothing.

    The caller must commit before raising. `get_db` rolls back on the error
    path, so an uncommitted counter here would be discarded precisely on the
    attempts that were supposed to count -- the same reasoning as the PIN
    throttle's failure-path commit.
    """
    await _clear_expired_lock(db, scope, key)

    now = _utcnow()
    until = _utc(now + lockout)
    statement = _counter_insert(db).values(
        id=new_uuid7(),
        scope=scope,
        key=key,
        attempts=1,
        locked_until=None,
        created_at=now,
        updated_at=now,
    )
    # `attempts + 1` on the right of `set_` refers to the *stored* value, not to
    # the value being assigned: both engines evaluate every assignment in a
    # single `DO UPDATE` against the row as it was before the update. That is
    # what makes the whole thing one atomic step rather than two.
    statement = statement.on_conflict_do_update(
        index_elements=[RateLimitCounter.scope, RateLimitCounter.key],
        set_={
            "attempts": RateLimitCounter.attempts + 1,
            "locked_until": case(
                (RateLimitCounter.attempts + 1 >= max_attempts, until),
                else_=RateLimitCounter.locked_until,
            ),
            "updated_at": now,
        },
    ).returning(RateLimitCounter.attempts, RateLimitCounter.locked_until)

    result = await db.execute(statement)
    attempts, locked_until = result.one()
    remaining = 0
    if locked_until is not None:
        remaining = (_utc(locked_until) - now).total_seconds()

    return AttemptOutcome(
        attempts=attempts,
        locked=remaining > 0,
        # `+ 1` so a client told to wait is never told to wait zero seconds.
        retry_after_seconds=int(remaining) + 1 if remaining > 0 else 0,
    )


async def reset(db: AsyncSession, scope: str, key: str) -> None:
    """Forget a counter, because the caller did something right.

    Only ever called for scopes a success is allowed to clear. See the module
    note on why the per-IP scope is not one of them.
    """
    now = _utcnow()
    await db.execute(
        update(RateLimitCounter)
        .where(
            RateLimitCounter.scope == scope,
            RateLimitCounter.key == key,
        )
        .values(attempts=0, locked_until=None, updated_at=now)
    )


def refuse(detail: str, retry_after_seconds: int) -> TooManyRequestsProblem:
    """A 429 carrying both the body field and the header RFC 6585 asks for."""
    return TooManyRequestsProblem(detail, retry_after_seconds=retry_after_seconds)
