"""Which course units an account is allowed to see, ask for help with, and tutor.

A student belongs to one faculty, and a faculty is the unit their course catalogue
is organised by. Someone who reads Computing should be offered the Computing units
and the tutors who teach them, and must not be able to reach Medicine's by asking
for them: the catalogue is per-faculty precisely because a student cannot tutor,
or be tutored in, a course their own faculty does not offer.

The rule lives here rather than in each caller because five places need it and they
must not drift apart. It is deliberately a *server* rule. The client already sends
its faculty as a filter, which is a convenience for rendering and not a boundary --
a filter the caller supplies is a filter the caller can leave out.

Units with no faculty at all (`course_units.subject_id` is nullable) are visible to
nobody. The seed warns about exactly this: an orphan unit looks like a broken filter
from the student's side and has no other symptom.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import false

from app.core.exceptions import ValidationProblem
from app.models.course_unit import CourseUnit
from app.models.user import User


def visible_to(query: Any, user: User) -> Any:
    """Narrow a `CourseUnit` query to the faculties `user` may see.

    Returns a query matching nothing when the account has not finished choosing a
    faculty, rather than an unfiltered one. An account mid-onboarding has no claim to
    the catalogue at all, and a missing filter must never mean "everything".
    """
    if user.faculty_id is None or user.university_id is None:
        return query.where(false())

    return query.where(
        CourseUnit.subject_id == user.faculty_id,
        CourseUnit.university_id == user.university_id,
    )


def require_faculty(user: User) -> None:
    """Refuse an action that needs a faculty, naming the step that is missing.

    A 422 with the field named, rather than an empty result: the caller asked to do
    something that has no meaning until onboarding finishes, and an empty list would
    read as "your faculty has no courses" rather than "you have not chosen one".
    """
    if user.faculty_id is None:
        raise ValidationProblem(
            "Choose your faculty before choosing course units.",
            errors={"faculty_id": "is required before course units can be chosen"},
        )


def require_own_faculty(unit: CourseUnit, user: User) -> None:
    """Refuse a course unit that is not the caller's own faculty's.

    Deliberately separate from `require_own_university`: the two failures are
    different mistakes, and a student who reached for a unit at another institution
    and a student who reached for their own faculty's neighbour both deserve to be
    told which boundary they hit.
    """
    if user.faculty_id is None or unit.subject_id != user.faculty_id:
        raise ValidationProblem(
            "That course unit belongs to a different faculty.",
            errors={"course_unit_id": "must be a course unit in your own faculty"},
        )


def require_own_university(unit: CourseUnit, user: User) -> None:
    """Refuse a course unit at another institution."""
    if unit.university_id != user.university_id:
        raise ValidationProblem(
            "That course unit belongs to a different university.",
            errors={"course_unit_id": "must be a course unit at your own university"},
        )


__all__ = [
    "require_faculty",
    "require_own_faculty",
    "require_own_university",
    "visible_to",
]
