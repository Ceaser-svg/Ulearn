"""Read-only reference data the onboarding wizard needs to populate its pickers.

No create, update, or delete. Universities, faculties, and course units are
administrator-loaded, and a student who could invent a course unit their own
transcript never mentioned could manufacture a match for it.

Course units are the one authenticated endpoint here. The rest describe an
institution to somebody choosing where to study, which is public; the course
catalogue is narrowed to the caller's own faculty, so the server has to know who is
asking before it can answer.
"""

import uuid

from fastapi import APIRouter
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.api.deps import CurrentUser, DatabaseSession
from app.models.course_unit import CourseUnit, Program, Subject, University
from app.models.grading_scale import Grade, GradingScale
from app.schemas.academic import (
    CourseUnitResponse,
    GradeResponse,
    GradingScaleResponse,
    ProgramResponse,
    SubjectResponse,
    UniversityResponse,
)
from app.services import faculty_scope

router = APIRouter(prefix="/academics", tags=["academics"])


@router.get(
    "/universities",
    response_model=list[UniversityResponse],
    summary="List institutions",
)
async def list_universities(db: DatabaseSession) -> list[UniversityResponse]:
    """Every institution, alphabetically.

    Unauthenticated on purpose. The sign-up form shows the student where they
    study before they have an account, and the data is public: a published
    faculty list leaks nothing a prospectus does not.
    """
    result = await db.execute(
        select(University)
        .options(selectinload(University.grading_scale))
        .order_by(University.name)
    )
    return [UniversityResponse.model_validate(row) for row in result.scalars()]


@router.get(
    "/grading-scales",
    response_model=list[GradingScaleResponse],
    summary="List grading scales",
)
async def list_grading_scales(db: DatabaseSession) -> list[GradingScaleResponse]:
    """Every institution's published grade scale."""
    result = await db.execute(select(GradingScale).order_by(GradingScale.name))
    return [GradingScaleResponse.model_validate(row) for row in result.scalars()]


@router.get(
    "/grades",
    response_model=list[GradeResponse],
    summary="List grades",
)
async def list_grades(
    db: DatabaseSession,
    university_id: uuid.UUID | None = None,
    grading_scale_id: uuid.UUID | None = None,
) -> list[GradeResponse]:
    """Grades for a university or scale.

    The tutor verification flow chooses a grade from the institution's published
    scale, and the app needs a first-class endpoint to list those choices.
    """
    query = select(Grade).options(selectinload(Grade.grading_scale))

    if university_id is not None:
        university = await db.scalar(
            select(University.grading_scale_id).where(
                University.public_id == university_id,
            )
        )
        if university is None:
            return []
        query = query.where(Grade.grading_scale_id == university)

    if grading_scale_id is not None:
        scale_uuid = await _grading_scale_uuid(db, grading_scale_id)
        if scale_uuid is None:
            return []
        query = query.where(Grade.grading_scale_id == scale_uuid)

    result = await db.execute(query.order_by(Grade.grading_scale_id, Grade.label))
    return [GradeResponse.model_validate(row) for row in result.scalars()]


@router.get(
    "/faculties",
    response_model=list[SubjectResponse],
    summary="List faculties and departments",
)
async def list_faculties(
    db: DatabaseSession,
    university_id: uuid.UUID,
) -> list[SubjectResponse]:
    """Every faculty for one university, alphabetically.

    Faculties are owned by a university, so the selected institution is required
    before the client can populate this list.
    """
    result = await db.execute(
        select(Subject)
        .options(selectinload(Subject.university))
        .where(Subject.university_id == await _university_uuid(db, university_id))
        .order_by(Subject.name)
    )
    return [SubjectResponse.model_validate(row) for row in result.scalars()]


@router.get(
    "/programs",
    response_model=list[ProgramResponse],
    summary="List university faculty programs",
)
async def list_programs(
    university_id: uuid.UUID,
    db: DatabaseSession,
) -> list[ProgramResponse]:
    """Every seeded program for a university, ordered by faculty and name."""
    result = await db.execute(
        select(Program)
        .options(selectinload(Program.university), selectinload(Program.faculty))
        .where(Program.university_id == await _university_uuid(db, university_id))
        .order_by(Program.faculty_id, Program.name)
    )
    return [ProgramResponse.model_validate(row) for row in result.scalars()]


@router.get(
    "/course-units",
    response_model=list[CourseUnitResponse],
    summary="List course units",
)
async def list_course_units(
    db: DatabaseSession,
    caller: CurrentUser,
    subject_id: uuid.UUID | None = None,
    university_id: uuid.UUID | None = None,
) -> list[CourseUnitResponse]:
    """The course units the caller may act on, narrowed by faculty.

    Always scoped to the caller's own faculty, whichever filters arrive on the query
    string. The filters exist for rendering -- the wizard asks for its faculty, the
    profile screen asks for the university -- and they can only ever narrow the
    answer further. A student who belongs to the Faculty of Computing is offered the
    Computing units, and cannot reach another faculty's by omitting a parameter,
    because the faculty is taken from the account rather than from the request.

    Authenticated for that reason. The other reference endpoints stay open, because a
    list of institutions and faculties is public information; a course catalogue
    scoped to one person is not.

    Ordered by code, because a student scanning for `BIT 221` is looking for a
    code, not for alphabetical position.
    """
    query = faculty_scope.visible_to(
        select(CourseUnit).options(
            selectinload(CourseUnit.university),
            selectinload(CourseUnit.subject),
            selectinload(CourseUnit.grade),
        ),
        caller.user,
    )
    if subject_id is not None:
        subject_uuid = await _subject_uuid(db, subject_id)
        if subject_uuid is None:
            return []
        query = query.where(CourseUnit.subject_id == subject_uuid)

    if university_id is not None:
        uni_uuid = await _university_uuid(db, university_id)
        if uni_uuid is None:
            return []
        query = query.where(CourseUnit.university_id == uni_uuid)

    result = await db.execute(query.order_by(CourseUnit.university_id, CourseUnit.code))
    return [CourseUnitResponse.model_validate(row) for row in result.scalars()]


async def _subject_uuid(db: AsyncSession, public_id: uuid.UUID) -> uuid.UUID | None:
    """The primary key for a faculty public id, or `None`.

    An unrecognised filter returns an empty list rather than a 404. The client
    filtered on a value it believes exists, so the honest answer to "units in
    this faculty" is "none" -- a 404 would put the wizard into an error state for
    something the student did not do.
    """
    result = await db.execute(select(Subject.id).where(Subject.public_id == public_id))
    return result.scalar_one_or_none()


async def _university_uuid(db: AsyncSession, public_id: uuid.UUID) -> uuid.UUID | None:
    """The primary key for a university public id, or `None`."""
    result = await db.execute(
        select(University.id).where(University.public_id == public_id)
    )
    return result.scalar_one_or_none()


async def _grading_scale_uuid(
    db: AsyncSession,
    public_id: uuid.UUID,
) -> uuid.UUID | None:
    """The primary key for a grading scale public id, or `None`."""
    result = await db.execute(
        select(GradingScale.id).where(GradingScale.public_id == public_id)
    )
    return result.scalar_one_or_none()
