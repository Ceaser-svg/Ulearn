"""Help request and session schemas.

A request is what a student asks for; a session is what happened. They are
separate resources on the wire as well as in the database, because a request can
sit unmatched or be withdrawn and must not appear as a session that never
occurred.

Status is never accepted from a client. A request or a session moves through
`status`, and the only field a client may set is the one its own action implies:
`cancelled_reason` and `cancelled_by` are recorded by the service from the
caller, because a client that can set them would let one user cancel another's
session and blame them.
"""

import uuid
from datetime import datetime
from typing import Self

from pydantic import Field, model_validator

from app.models.enums import HelpRequestStatus, SessionStatus
from app.schemas.base import OrmSchema, RequestSchema, Trimmed

MIN_TOPIC_LENGTH = 3
MAX_TOPIC_LENGTH = 200
MAX_DESCRIPTION_LENGTH = 2000
MAX_CANCELLATION_REASON_LENGTH = 500

MIN_DURATION_MINUTES = 1
MAX_DURATION_MINUTES = 480

#: The handshake pin is exactly two digits, matching `sessions.session_pin`'s
#: `String(2)` and its `session_pin_length` check constraint. Bounded here so an
#: oversized candidate is a validation error naming the field rather than a wrong
#: PIN the tutee is told to try again with.
MAX_PIN_LENGTH = 2


class HelpRequestCreate(RequestSchema):
    """A student asking for help with a course unit.

    `topic` is required even though the course unit is known, because "MAT 221"
    is a course and "eigenvalues and diagonalisation" is the question, and a
    tutor deciding whether to accept needs the second one.
    """

    course_unit_id: uuid.UUID
    topic: Trimmed = Field(min_length=MIN_TOPIC_LENGTH, max_length=MAX_TOPIC_LENGTH)
    description: Trimmed | None = Field(
        default=None,
        max_length=MAX_DESCRIPTION_LENGTH,
        description="Optional detail, and not matched on.",
    )


class SelectTutorRequest(RequestSchema):
    """A student naming the tutor they have chosen from the proposals.

    One field, and it is deliberately not enough to be trusted. The service
    re-derives the eligible candidates for the request's own course unit and
    refuses a tutor who is not among them, because a request body is whatever
    the caller chose to send: invariant 1 is a server rule, and the fact that an
    id once appeared in a list the client holds is not evidence about the tutor's
    competency, grade, or standing now.

    Called `candidate_tutor_id` rather than the bare `tutor_id` the responses
    use, because a request body may not carry a plainly-named user id -- that
    spelling is read as a primary key that leaked onto the wire, and
    `test_no_request_schema_accepts_an_id_field` holds it out. What the field
    selects is the column the response then calls `matched_tutor_id`.
    """

    candidate_tutor_id: uuid.UUID


class HelpRequestResponse(OrmSchema):
    """A request as its owner and as a candidate tutor see it."""

    id: uuid.UUID = Field(validation_alias="public_id")
    tutee_id: uuid.UUID = Field(validation_alias="tutee_public_id")
    course_unit_id: uuid.UUID = Field(validation_alias="course_unit_public_id")
    topic: str
    description: str | None = None
    status: HelpRequestStatus
    matched_tutor_id: uuid.UUID | None = Field(
        default=None, validation_alias="matched_tutor_public_id"
    )
    created_at: datetime


class SessionCreate(RequestSchema):
    """Booking a session against a matched request.

    `duration_minutes` is bounded at both ends. There is no floor of zero: a
    zero-length session would complete instantly and contribute to a
    certificate's hours, and there is no ceiling case either -- eight hours is
    past the longest a tutoring session plausibly runs, and an unbounded integer
    would let one row claim a year's worth of hours.
    """

    help_request_id: uuid.UUID | None = Field(
        default=None,
        description="The request being accepted, when there is one.",
    )
    course_unit_id: uuid.UUID
    topic: Trimmed = Field(min_length=MIN_TOPIC_LENGTH, max_length=MAX_TOPIC_LENGTH)
    duration_minutes: int = Field(ge=MIN_DURATION_MINUTES, le=MAX_DURATION_MINUTES)
    scheduled_start: datetime | None = None
    meeting_link: Trimmed | None = Field(
        default=None,
        max_length=500,
        description="Optional Google Meet / Zoom link the tutor shares.",
    )

    @model_validator(mode="after")
    def start_is_in_the_future(self) -> Self:
        """A session cannot be scheduled in the past.

        Checked here rather than in the service because it is a property of the
        request, not of any existing state. A naive datetime is rejected by the
        comparison below, so a client in a timezone it did not mean cannot
        schedule a session that silently lands yesterday.
        """
        if self.scheduled_start is not None:
            if self.scheduled_start.tzinfo is None:
                raise ValueError("scheduled_start must include a timezone offset")
            if (
                self.scheduled_start.timestamp()
                <= datetime.now(self.scheduled_start.tzinfo).timestamp()
            ):
                raise ValueError("scheduled_start must be in the future")
        return self


class SessionTransitionRequest(RequestSchema):
    """A caller moving a session to a new status.

    Only `status` and, for a cancellation, a reason. The service checks the move
    against `SESSION_TRANSITIONS` and records who did it; the client cannot
    assert that a session was completed, and cannot name a different actor.
    """

    status: SessionStatus
    cancellation_reason: Trimmed | None = Field(
        default=None, max_length=MAX_CANCELLATION_REASON_LENGTH
    )
    # No `pin` field. Starting a session is `POST /v1/sessions/{id}/verify-pin`
    # and nothing else: the pin used to be accepted here as well, with no attempt
    # counter, which made the throttle on the real endpoint optional. Accepting a
    # field and ignoring it would be worse than removing it, so a client still
    # sending one gets a 422 from `extra="forbid"` rather than a silent success.

    @model_validator(mode="after")
    def reason_required_when_cancelling(self) -> Self:
        """A cancellation must say why.

        Both parties need it. The tutor deciding whether to keep teaching for
        this student, and the platform deciding whether a cancellation is a
        pattern. An unexplained cancellation is the single most common cause of a
        disputed rating, and it is the cheapest thing to record.
        """
        if self.status is SessionStatus.CANCELLED and not (
            self.cancellation_reason and self.cancellation_reason.strip()
        ):
            raise ValueError("cancellation_reason is required when cancelling")
        return self

    @model_validator(mode="after")
    def reason_rejected_when_not_cancelling(self) -> Self:
        """Only a cancellation carries a reason.

        Dropped silently otherwise so a client that reuses one form for every
        transition does not have to branch, and a stored reason cannot contradict
        a completed session.
        """
        if self.status is not SessionStatus.CANCELLED:
            object.__setattr__(self, "cancellation_reason", None)
        return self


class SessionResponse(OrmSchema):
    """A session as either party sees it.

    Carries both parties' public ids because both need to name the other, and
    because the two clients are the same app.
    """

    id: uuid.UUID = Field(validation_alias="public_id")
    help_request_id: uuid.UUID | None = Field(
        default=None, validation_alias="help_request_public_id"
    )
    tutee_id: uuid.UUID = Field(validation_alias="tutee_public_id")
    tutor_id: uuid.UUID = Field(validation_alias="tutor_public_id")
    course_unit_id: uuid.UUID = Field(validation_alias="course_unit_public_id")
    topic: str
    status: SessionStatus
    scheduled_start: datetime | None = None
    started_at: datetime | None = None
    ended_at: datetime | None = None
    duration_minutes: int = Field(ge=0)
    meeting_link: str | None = Field(
        default=None, description="Shared meeting link for the session."
    )
    is_rated: bool = Field(
        description=(
            "Whether a rating exists yet. The client needs this to decide whether "
            "to prompt for one; a completed session is not rated yet is the state "
            "the prompt exists for."
        )
    )
    created_at: datetime


class SessionPinResponse(OrmSchema):
    """The handshake pin, for the tutor who has to read it aloud.

    Split out from `SessionResponse` rather than added there as an optional field
    because the pin belongs to one party. In the shared response it was readable
    by the tutee as well, which made the handshake something the tutee could
    simply skip: there was no secret left to prove knowledge of.
    """

    session_id: uuid.UUID
    session_pin: str = Field(
        description="The two digits the tutor reads out for the tutee to enter."
    )
    attempts_remaining: int = Field(
        ge=0,
        description=(
            "Wrong entries left before the tutee is put on a cooldown. The tutor "
            "can see the lock coming and say the right thing instead of letting a "
            "student stand there guessing."
        ),
    )


class VerifyPinRequest(RequestSchema):
    """The digits the tutee is entering.

    A schema rather than the `dict[str, str]` the route used to accept: an
    untyped body means a missing `pin` arrives as `""` and fails later as an
    incorrect PIN, so a client bug is reported to the user as a wrong PIN.
    """

    pin: str = Field(
        min_length=1,
        max_length=MAX_PIN_LENGTH,
        description="The two digits the tutor read out.",
    )
