"""Competency schemas: what a tutor has proved, and how it was checked.

A competency is a claim until it is `verified`. The client shows the difference,
so both the status and the reason for a rejection travel in the response -- a
tutor who uploaded a transcript and was refused with no explanation has no way to
fix it, and will simply not try again.
"""

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import Field

from app.models.enums import CompetencyStatus, VerificationSource
from app.schemas.base import OrmSchema, RequestSchema

MAX_EVIDENCE_REFERENCE_LENGTH = 500
MAX_NOTES_LENGTH = 2000


class CompetencyCreate(RequestSchema):
    """A tutor claiming competence in a course unit.

    `grade_id` is the catalogue entry, not a raw number. A client that could post
    `grade_points` directly would let a tutor claim an A on a scale their
    university does not use, and the threshold check would compare two
    incompatible numbers.
    """

    course_unit_id: uuid.UUID = Field(
        description="The course unit's public id.",
    )
    grade_id: uuid.UUID = Field(
        description="The grade's public id, from that unit's grading scale.",
    )
    source: VerificationSource
    evidence_reference: str | None = Field(
        default=None,
        max_length=MAX_EVIDENCE_REFERENCE_LENGTH,
        description=(
            "Where the evidence lives: a transcript reference, a portfolio URL. "
            "Stored, not fetched -- the API does not crawl student documents."
        ),
    )
    notes: str | None = Field(default=None, max_length=MAX_NOTES_LENGTH)


class CompetencyResponse(OrmSchema):
    """A competency as the client sees it.

    `meets_threshold` is computed by the service from the grade on the scale's
    bar, and is sent so the tutor's own profile can show the gap. It is a
    convenience, not the rule: matching consults the stored status and grade
    rather than trusting a boolean over the wire.

    The unit and the grade travel as names and labels as well as ids. This
    response is the only thing a tutor has after submitting, so it is what the
    "my applications" screen reads -- and a list of opaque unit ids tells a
    student nothing about which of their proofs is waiting. The ids remain: they
    are what a client identifies a unit by.
    """

    id: uuid.UUID = Field(validation_alias="public_id")
    user_id: uuid.UUID = Field(validation_alias="user_public_id")
    course_unit_id: uuid.UUID = Field(validation_alias="course_unit_public_id")
    course_unit_code: str
    course_unit_name: str
    grade_id: uuid.UUID = Field(validation_alias="grade_public_id")
    grade_label: str
    status: CompetencyStatus
    source: VerificationSource
    grade_points: Decimal = Field(max_digits=6, decimal_places=2)
    meets_threshold: bool
    verified_at: datetime | None = None
    rejection_reason: str | None = None
    evidence_reference: str | None = None
    created_at: datetime
