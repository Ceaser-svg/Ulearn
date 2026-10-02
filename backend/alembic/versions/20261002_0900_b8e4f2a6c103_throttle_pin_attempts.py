"""throttle handshake pin attempts.

Revision ID: b8e4f2a6c103
Revises: a7c9e1d4f602
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b8e4f2a6c103"
down_revision: str | None = "a7c9e1d4f602"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # `server_default` rather than a nullable column with no default: sessions
    # already exist, and a NOT NULL add with a default rewrites the table once
    # on PostgreSQL, whereas leaving it nullable would mean every read site
    # having to cope with three states for a counter that is conceptually one.
    op.add_column(
        "sessions",
        sa.Column(
            "pin_failed_attempts",
            sa.Integer(),
            nullable=False,
            server_default="0",
        ),
    )
    op.add_column(
        "sessions",
        sa.Column("pin_locked_until", sa.DateTime(timezone=True), nullable=True),
    )
    # Bare suffix: the metadata naming convention expands this to
    # `ck_sessions_pin_failed_attempts_not_negative`. Spelling the prefix here as
    # well produced `ck_sessions_ck_sessions_...`, and a constraint whose name
    # disagrees with the model's is a name `alembic check` cannot reconcile.
    op.create_check_constraint(
        "pin_failed_attempts_not_negative",
        "sessions",
        "pin_failed_attempts >= 0",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_sessions_pin_failed_attempts_not_negative", "sessions", type_="check"
    )
    op.drop_column("sessions", "pin_locked_until")
    op.drop_column("sessions", "pin_failed_attempts")