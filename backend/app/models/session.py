"""Help requests and the sessions they become.

A request and a session are separate tables, which the earlier design did not
have. A student can ask for help and never be matched: the request is withdrawn
or expires. Modelling that as a session row would leave the schema claiming a
tutor session exists for a request that never found one, and every query about
tutor workload would have to filter those rows out.
"""

import random
import uuid
from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
    select,
)
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.core.security import new_uuid7
from app.models.base import (
    TimestampMixin,
    enum_column,
    public_id_column,
)
from app.models.enums import HelpRequestStatus, SessionStatus

# `Rating` is a runtime import, not a TYPE_CHECKING one, because `is_rated`
# queries it. This is safe: `app.models.rating` refers back to `Session` only
# inside TYPE_CHECKING, so the two modules do not import each other at runtime.
from app.models.rating import Rating

if TYPE_CHECKING:
    from app.models.course_unit import CourseUnit
    from app.models.user import User


class HelpRequest(Base, TimestampMixin):
    """A student asking for help with one course unit.

    Kept after it is matched or closed. A student who asks the same question in
    three units over a term is a pattern the matching engine will want, and
    discarding the request would discard the only record of it.
    """

    __tablename__ = "help_requests"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=new_uuid7)
    public_id: Mapped[uuid.UUID] = public_id_column()

    tutee_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    course_unit_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("course_units.id", ondelete="RESTRICT"), nullable=False, index=True
    )

    #: The specific concept, as the student worded it. This is the text the
    #: matching engine reads to rank candidates within a unit; the unit decides
    #: who is eligible at all.
    topic: Mapped[str] = mapped_column(String(200), nullable=False)

    description: Mapped[str | None] = mapped_column(Text, nullable=True)

    status: Mapped[HelpRequestStatus] = mapped_column(
        enum_column(HelpRequestStatus, name="help_request_status"),
        nullable=False,
        default=HelpRequestStatus.OPEN,
        index=True,
    )

    #: Set when a tutor was matched. Retained after the session closes so the
    #: request's history does not depend on the session's.
    matched_tutor_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    tutee: Mapped[User] = relationship(foreign_keys=[tutee_id])
    course_unit: Mapped[CourseUnit] = relationship()
    matched_tutor: Mapped[User | None] = relationship(foreign_keys=[matched_tutor_id])
    sessions: Mapped[list[Session]] = relationship(back_populates="help_request")

    def __repr__(self) -> str:
        return f"<HelpRequest {self.public_id} {self.status}>"

    #: Public ids of the resources this row references.
    #:
    #: A response schema that declared `course_unit_id` without an alias would
    #: have `from_attributes` hand it the internal primary key, which looks
    #: plausible in a test and leaks the key in production. These exist so the
    #: public id is what the field can only ever receive.
    #:
    #: They read a relationship, so the service must eager-load it. On an async
    #: session a lazy load raises `MissingGreenlet` rather than quietly costing a
    #: query, which is the behaviour wanted here: a missing `selectinload` should
    #: be a crash, not an N+1 that only shows up under load.

    @property
    def tutee_public_id(self) -> uuid.UUID:
        return self.tutee.public_id

    @property
    def course_unit_public_id(self) -> uuid.UUID:
        return self.course_unit.public_id

    @property
    def matched_tutor_public_id(self) -> uuid.UUID | None:
        return self.matched_tutor.public_id if self.matched_tutor else None


class Session(Base, TimestampMixin):
    """A tutoring session between a student and a tutor.

    `duration_minutes` is recorded, not derived from the timestamps. Deriving it
    from `ended_at - started_at` would bill a tutor for a session left running
    on a phone that was never closed, and a tutor's certificate depends on this
    number being defensible.
    """

    __tablename__ = "sessions"
    __table_args__ = (
        UniqueConstraint("help_request_id", name="session_per_request"),
        CheckConstraint("duration_minutes >= 0", name="duration_non_negative"),
        CheckConstraint("tutee_id <> tutor_id", name="session_parties_differ"),
        CheckConstraint(
            "session_pin IS NULL OR length(session_pin) = 2",
            name="session_pin_length",
        ),
        # The throttle increments on its error path, so a negative count would
        # mean a lockout counter that runs backwards.
        CheckConstraint(
            "pin_failed_attempts >= 0",
            name="pin_failed_attempts_not_negative",
        ),
        # A completed session needs a start and an end, or the hours it
        # contributes to a certificate cannot be established.
        CheckConstraint(
            "status <> 'completed' "
            "OR (started_at IS NOT NULL AND ended_at IS NOT NULL)",
            name="completed_session_has_times",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=new_uuid7)
    public_id: Mapped[uuid.UUID] = public_id_column()

    #: A tutoring session always starts from a problem the student asked for.
    #:
    #: Nullable at the database level, but `create_session` requires it, so in
    #: practice every session descends from a help request. The column stays
    #: nullable for the migration that introduces it and for `ON DELETE SET
    #: NULL`: a request the student withdraws must not take the session that
    #: already happened with it. The session is the record, not the request.
    #:
    #: There is no "tutor offers a session directly" path, and there should not
    #: be one in the MVP. A session with no request would have no statement of
    #: what the student wanted help with, and a tutor could create hours
    #: against any student who is not themselves -- which is the same way
    #: certificate minutes could be inflated without a counterparty's intent.
    help_request_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("help_requests.id", ondelete="SET NULL"), nullable=True
    )

    tutee_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    tutor_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )

    course_unit_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("course_units.id", ondelete="RESTRICT"), nullable=False, index=True
    )

    status: Mapped[SessionStatus] = mapped_column(
        enum_column(SessionStatus, name="session_status"),
        nullable=False,
        default=SessionStatus.SCHEDULED,
        index=True,
    )

    topic: Mapped[str] = mapped_column(String(200), nullable=False)

    scheduled_start: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    started_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    ended_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    duration_minutes: Mapped[int] = mapped_column(nullable=False, default=0)
    session_pin: Mapped[str | None] = mapped_column(String(2), nullable=True)

    #: Consecutive wrong PINs. The pin is two digits, so there are 100 candidates
    #: and no attempt ceiling is the same as no handshake at all.
    #:
    #: Stored on the row rather than in memory because an in-process counter is
    #: cleared by a restart and is per-worker, so it is weakest exactly when the
    #: service is busiest and most worth attacking.
    pin_failed_attempts: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )

    #: When the tutee stopped being able to try again. Null means not locked.
    #: A cooldown rather than a permanent lock: the session still has to be
    #: startable, and the tutor is standing there waiting.
    pin_locked_until: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    meeting_link: Mapped[str | None] = mapped_column(String(500), nullable=True)

    cancelled_by_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )

    cancellation_reason: Mapped[str | None] = mapped_column(String(500), nullable=True)

    help_request: Mapped[HelpRequest | None] = relationship(back_populates="sessions")
    course_unit: Mapped[CourseUnit] = relationship()
    tutee: Mapped[User] = relationship(foreign_keys=[tutee_id])
    tutor: Mapped[User] = relationship(foreign_keys=[tutor_id])
    #: `passive_deletes` because the foreign key is already ON DELETE CASCADE.
    #: Without it the ORM loads every rating to delete it one at a time, which
    #: is both slower and a chance to lose a row the database would have removed
    #: anyway.
    ratings: Mapped[list[Rating]] = relationship(
        back_populates="session", passive_deletes=True
    )

    @staticmethod
    def generate_session_pin() -> str:
        """A two-digit handshake pin the backend verifies.

        The platform owns the value rather than the client: a student can reveal
        the pin to a tutor, but neither party can generate or mutate it on their
        own when they accept or start the session.
        """
        return f"{random.randint(0, 99):02d}"

    async def is_rated(self, db: AsyncSession) -> bool:
        """Whether anyone has rated this session yet.

        The building block for the "a completed session requires a rating" rule.
        The rule itself lives in the session service, because no single table can
        enforce it; see the note in `app.models.rating`.

        Takes the session and returns a coroutine rather than reading
        `self.ratings`, because a plain attribute would lazy-load the
        relationship and a lazy load cannot be awaited on an async session. It
        would raise `MissingGreenlet` at the first call from a request handler.
        A `SELECT EXISTS` is also cheaper than loading the rows.
        """
        result = await db.execute(
            select(func.count()).select_from(Rating).where(Rating.session_id == self.id)
        )
        return bool(result.scalar_one())

    def __repr__(self) -> str:
        return f"<Session {self.public_id} {self.status}>"

    #: Public ids of the resources this row references.
    #:
    #: A response schema that declared `course_unit_id` without an alias would
    #: have `from_attributes` hand it the internal primary key, which looks
    #: plausible in a test and leaks the key in production. These exist so the
    #: public id is what the field can only ever receive.
    #:
    #: They read a relationship, so the service must eager-load it. On an async
    #: session a lazy load raises `MissingGreenlet` rather than quietly costing a
    #: query, which is the behaviour wanted here: a missing `selectinload` should
    #: be a crash, not an N+1 that only shows up under load.

    @property
    def tutee_public_id(self) -> uuid.UUID:
        return self.tutee.public_id

    @property
    def tutor_public_id(self) -> uuid.UUID:
        return self.tutor.public_id

    @property
    def course_unit_public_id(self) -> uuid.UUID:
        return self.course_unit.public_id

    @property
    def help_request_public_id(self) -> uuid.UUID | None:
        return self.help_request.public_id if self.help_request else None
