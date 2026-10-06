"""Transport types for the separate MUST admin surface."""

import uuid
from datetime import datetime
from typing import Self

from pydantic import Field, model_validator

from app.models.enums import (
    CompetencyStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.schemas.base import OrmSchema, RequestSchema, Trimmed
from app.schemas.common import Page, PageParams
from app.schemas.competency import MAX_EVIDENCE_REFERENCE_LENGTH


class AdminUserResponse(OrmSchema):
    """The minimum identity and status data staff need for pilot operations."""

    id: uuid.UUID
    email: str
    full_name: str | None
    roles: list[UserRole]
    university_id: uuid.UUID | None
    faculty_id: uuid.UUID | None
    year_of_study: int | None
    is_active: bool
    created_at: datetime


class AdminUserPage(Page[AdminUserResponse]):
    """A bounded page of users for the admin console."""


class AdminAuditEventResponse(OrmSchema):
    id: uuid.UUID = Field(validation_alias="public_id")
    actor_id: uuid.UUID
    actor_email: str
    actor_name: str | None
    action: str
    target_type: str
    target_public_id: uuid.UUID | None
    context: dict[str, object]
    created_at: datetime


class AdminAuditEventPage(Page[AdminAuditEventResponse]):
    """A bounded page of audit events."""


class AdminCompetencyResponse(OrmSchema):
    """The review fields staff need without embedding academic documents.

    The grade is sent as both a label and a number, and the bar it has to clear
    is sent with it. An operator deciding on a submission is judging exactly
    that comparison, and a server-side gate they cannot see is a gate they can
    only discover by being refused.
    """

    id: uuid.UUID
    user_id: uuid.UUID
    user_email: str
    user_name: str | None
    course_unit_id: uuid.UUID
    course_unit_code: str
    course_unit_name: str
    grade_label: str
    grade_points: str
    #: The lowest grade on this unit's scale that makes a tutor eligible, in
    #: the same points as `grade_points`. `None` when the unit's university has
    #: no grading scale loaded, which is a normal state, not a fault.
    competency_min_points: str | None
    #: Whether `grade_points` already clears `competency_min_points`.
    meets_threshold: bool
    status: CompetencyStatus
    source: VerificationSource
    evidence_reference: str | None
    rejection_reason: str | None
    #: When the submission was made. The queue is ordered by this, and it is how
    #: long a tutor has been waiting.
    created_at: datetime
    #: When the competency was verified, which is `None` for every other status.
    verified_at: datetime | None


class AdminCompetencyPage(Page[AdminCompetencyResponse]):
    """A bounded page of tutor evidence awaiting or completing review."""


class AdminCompetencyPageParams(PageParams):
    """The review queue's paging plus the one filter an operator actually uses.

    `status` is a narrow filter and deliberately not a generic query object. The
    queue is triaged by status -- work through everything pending, then look at
    what was rejected -- and a general filter language over an audit surface is
    more authority than the job needs.
    """

    status: CompetencyStatus | None = Field(
        default=None,
        description="Only rows in this status. Omit for every status.",
    )


class AdminCompetencyReviewRequest(RequestSchema):
    """An audited admin decision on a tutor competency.

    The two rules below were originally on the student-facing review schema,
    which was removed: review is an operator action, and an owner reviewing their
    own submission is not a review at all. They moved here with the route rather
    than being dropped, because a tutor who is refused with no explanation cannot
    act on it and will not try again -- and MUST_Pilot_Operations requires a
    rejection to carry a reason the tutor can act on.
    """

    status: CompetencyStatus
    rejection_reason: Trimmed | None = Field(
        default=None,
        max_length=MAX_EVIDENCE_REFERENCE_LENGTH,
        description=(
            "Required when rejecting. Must be something the tutor can act on, "
            "and must not quote their evidence back at them."
        ),
    )

    @model_validator(mode="after")
    def reason_required_when_rejected(self) -> Self:
        """A rejection must say why.

        Enforced here rather than in the service so the console gets a
        field-level message naming `rejection_reason` instead of a 422 that does
        not say which field was at fault.
        """
        if self.status is CompetencyStatus.REJECTED and not (
            self.rejection_reason and self.rejection_reason.strip()
        ):
            raise ValueError("rejection_reason is required when rejecting a competency")
        return self

    @model_validator(mode="after")
    def reason_rejected_when_verified(self) -> Self:
        """A verification carries no rejection reason.

        Not a hard failure -- an operator may be correcting a mistake -- but
        storing one alongside `verified` would leave a record asserting both.
        """
        if self.status is not CompetencyStatus.REJECTED:
            object.__setattr__(self, "rejection_reason", None)
        return self


class AdminTutorStandingResponse(OrmSchema):
    """Operational tutor standing and aggregate rating data."""

    user_id: uuid.UUID
    user_email: str
    user_name: str | None
    standing: TutorStanding
    completed_sessions: int
    rating_count: int
    average_rating: str | None


class AdminTutorStandingPage(Page[AdminTutorStandingResponse]):
    """A bounded page of tutor standing summaries."""
