"""Append-only records of privileged administrative actions."""

import uuid
from typing import TYPE_CHECKING

from sqlalchemy import JSON, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.core.security import new_uuid7
from app.models.base import TimestampMixin, public_id_column

if TYPE_CHECKING:
    from app.models.user import User


class AdminAuditEvent(Base, TimestampMixin):
    """A safe description of one admin action.

    Request bodies, tokens, passwords, and academic evidence are deliberately
    absent. The event stores identifiers and an action name so an operator can
    explain who changed what without turning the audit table into a second
    sensitive-data store.

    The actor's name is read through [actor] rather than copied onto the row.
    Storing it would freeze the name as it was at the time, which sounds like
    history but is not: an operator can correct a typo in their name, and a log
    that kept the old one would contradict the users table.
    """

    __tablename__ = "admin_audit_events"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=new_uuid7)
    public_id: Mapped[uuid.UUID] = public_id_column()
    actor_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    action: Mapped[str] = mapped_column(String(80), nullable=False)
    target_type: Mapped[str] = mapped_column(String(80), nullable=False)
    target_public_id: Mapped[uuid.UUID | None] = mapped_column(nullable=True)
    context: Mapped[dict[str, object]] = mapped_column(
        JSON, nullable=False, default=dict
    )

    # `lazy="joined"` because every read of this table is a list for an operator
    # who needs to see who acted, and there is no path that wants the event
    # without it.
    actor: Mapped[User] = relationship(lazy="joined")
