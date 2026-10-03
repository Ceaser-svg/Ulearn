"""Counters that back the rate limiter.

One row per (scope, key) pair. The service reads it to decide whether a caller
is inside a cooldown, and increments it atomically when an attempt fails.
"""

import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.core.security import new_uuid7
from app.models.base import TimestampMixin, public_id_column


class RateLimitCounter(Base, TimestampMixin):
    """How many times one caller has failed recently, and until when they are out.

    Lives in the database rather than in a dictionary for the same reason the
    PIN counters live on the session row: an in-process counter is cleared by a
    restart and is per-worker, so it is weakest exactly when the service is
    busiest and most worth attacking. With more than one worker process, an
    in-memory limiter is divided by the worker count -- an attacker gets the
    configured number of tries per worker, for free.

    `attempts` counts consecutive failures within the current lock cycle. It is
    reset to zero when a lock expires, not by a sliding window, which bounds the
    column at `max_attempts` rather than letting it grow without limit. A scope
    whose successes reset the counter (the per-account sign-in scope) is reset
    explicitly on success; one whose successes must not reset it (the per-IP
    scope, see `app.services.rate_limit`) is not, so that an attacker holding a
    single valid account cannot launder their own attempt budget by signing in.
    """

    __tablename__ = "rate_limit_counters"
    __table_args__ = (
        # One counter per scope per key. This is the constraint the limiter's
        # atomic increment depends on: `ON CONFLICT (scope, key)` is what makes
        # two parallel failures count as two rather than one.
        UniqueConstraint("scope", "key", name="scope_key"),
        # A negative count would mean a limiter running backwards.
        CheckConstraint("attempts >= 0", name="attempts_not_negative"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=new_uuid7)

    #: Carried for the same reason as on every other model: the codebase-wide
    #: invariant is that no mapped model is reachable only by primary key. This
    #: row is never returned by an endpoint, so nothing reads this column -- but
    #: granting an exception for one table means the next one gets one too, and
    #: the check that keeps internal keys out of responses quietly stops being
    #: absolute.
    public_id: Mapped[uuid.UUID] = public_id_column()

    #: What is being counted, e.g. `auth.login.account` or `auth.login.ip`.
    #: Part of the identity of the row rather than a free-text label, so two
    #: scopes cannot share a counter even when their keys coincide -- a student's
    #: email address is, after all, not an IP address, but "127.0.0.1" is a legal
    #: local part and the two must not collide.
    scope: Mapped[str] = mapped_column(String(64), nullable=False)

    #: The thing being counted within the scope: a normalised email address, or a
    #: client IP. Indexed with `scope` because every lookup filters on the pair.
    key: Mapped[str] = mapped_column(String(255), nullable=False)

    attempts: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )

    #: When this caller stops being locked out. Null means not locked.
    locked_until: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    def __repr__(self) -> str:
        return f"<RateLimitCounter {self.scope} {self.key} attempts={self.attempts}>"
