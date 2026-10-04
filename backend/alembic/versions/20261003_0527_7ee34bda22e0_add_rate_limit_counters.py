"""add rate limit counters.

Revision ID: 7ee34bda22e0
Revises: b8e4f2a6c103
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7ee34bda22e0"
down_revision: str | None = "b8e4f2a6c103"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "rate_limit_counters",
        sa.Column("id", sa.Uuid(), nullable=False),
        # Unused by any endpoint, and declared anyway: every mapped model in this
        # codebase carries one, and that check is absolute. See the model's
        # docstring.
        sa.Column("public_id", sa.Uuid(), nullable=False),
        sa.Column("scope", sa.String(length=64), nullable=False),
        sa.Column("key", sa.String(length=255), nullable=False),
        # `server_default` because the table can already be written by a running
        # older revision's tests while this deploys. A nullable column with no
        # default would mean every write site coping with two states for a
        # counter that is conceptually one.
        sa.Column("attempts", sa.Integer(), server_default="0", nullable=False),
        sa.Column("locked_until", sa.DateTime(timezone=True), nullable=True),
        # No `server_default` on the timestamps, unlike `attempts`. These are
        # written by the ORM on every insert and are never added to an existing
        # table, so there is no path on which a row arrives without them.
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        # Bare suffix: the metadata naming convention expands this to
        # `ck_rate_limit_counters_attempts_not_negative`. Spelling the prefix here
        # as well produced `ck_..._ck_..._...` in an earlier attempt, and a
        # constraint whose name disagrees with the model's is a name `alembic
        # check` cannot reconcile.
        sa.CheckConstraint(
            "attempts >= 0",
            name=op.f("ck_rate_limit_counters_attempts_not_negative"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rate_limit_counters")),
        # Not `op.f("uq_...")`. The `uq` convention has no `%(constraint_name)s`
        # in it, so an explicitly named unique constraint is used verbatim -- the
        # same is true of `rating_per_rater` on the ratings table. Expanding it
        # here would have produced a name the model does not declare, and
        # `alembic check` reports that as drift.
        #
        # This constraint is load-bearing rather than decorative: it is the
        # `ON CONFLICT (scope, key)` target of the limiter's atomic increment,
        # and it is what keeps two parallel failures counting as two.
        sa.UniqueConstraint("scope", "key", name="scope_key"),
    )
    op.create_index(
        op.f("ix_rate_limit_counters_public_id"),
        "rate_limit_counters",
        ["public_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_table("rate_limit_counters")