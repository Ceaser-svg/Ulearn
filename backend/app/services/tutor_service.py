"""Tutor discovery: the rail a student browses, and one tutor's public profile.

Both entry points are read-only and both are student-facing, which fixes two
things they may never do.

They may not create a `TutorProfile`. A row exists for a user holding the tutor
role and is created when the role is granted, in `validation_service`. A browse
that minted one would hand every signed-in student a `probationary` standing and
zero counters merely by opening the discovery screen -- which is exactly the bug
`rating_service.get_tutor_rating_summary` was fixed for. Nothing here writes, and
`tests/test_tutor_rail.py` asserts the row count is unchanged after every `GET`.

They may not show a suspended tutor. `SUSPENDED` is excluded from the rail in
the query rather than filtered out afterwards, so a suspended tutor cannot reach
a student-facing list even if a later filter is added above it. The detail
screen is the deliberate exception: a student who already booked that tutor has
to be able to see that the standing is `suspended`, and
`TutorProfileSummary` says so.

This is a discovery surface, not matching. It answers "who is strong here",
where `matching_service` answers "who may take this request". They share the
competency gate -- a verified grade at or above the scale's
`competency_min_points`, which is invariant 1 -- and nothing else. The rail does
not widen to a subject, does not rank by a session's proximity, and does not
consult availability: it is a browsable shortlist, and matching remains the only
place a tutor is proposed for work.
"""

import uuid
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import NotFoundProblem, ValidationProblem
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, University
from app.models.endorsement import UnitEndorsement
from app.models.enums import CompetencyStatus, TutorStanding
from app.models.grading_scale import Grade, GradingScale
from app.models.tutor_profile import TutorProfile
from app.models.user import User
from app.schemas.tutor import (
    DEFAULT_RAIL_TUTORS,
    RAIL_ENDORSED_UNITS,
    TutorDetailResponse,
    TutorProfileSummary,
    TutorRailEntry,
)
from app.services import rating_service


async def list_top_tutors(
    db: AsyncSession,
    user: User,
    *,
    course_unit_id: uuid.UUID | None = None,
    limit: int = DEFAULT_RAIL_TUTORS,
) -> list[TutorRailEntry]:
    """The signed-in student's rail of tutors worth looking at.

    `course_unit_id` narrows the rail to tutors who pass the competency gate in
    that unit. Omitting it considers every verified competency the student's own
    university holds, so the rail is useful on a screen that has no unit picker
    yet rather than empty until one is chosen.

    Either way the rail is the student's own faculty's. A unit in another faculty,
    and a tutor teaching one, are both outside what the student can ask for help
    with, so offering them would be offering a conversation with no course in it.
    This is the discovery boundary and it is enforced here rather than left to the
    picker: `get_tutor_detail` deliberately stays open so a shared link still works,
    which is only defensible while the rail stays inside the faculty.

    The gate is the same one in both paths, and it reads as if the unfiltered
    path were the looser one. It is not, and cannot be: every course unit at one
    university is graded on that university's single scale, so "at or above
    `competency_min_points`" is a statement about the university rather than
    about a unit. Applying it only when a unit was named would mean the same
    tutor passes in one query and fails in the other depending on which screen
    asked, which is not a rule anyone could learn.
    """
    if user.university_id is None:
        raise ValidationProblem(
            "Choose your university before browsing tutors.",
            errors={"university_id": "university is required"},
        )

    scope: CourseUnit | None = None
    if course_unit_id is not None:
        scope = await _load_course_unit(db, course_unit_id)
        if (
            scope is None
            or scope.university_id != user.university_id
            or user.faculty_id is None
            or scope.subject_id != user.faculty_id
        ):
            # An empty rail rather than a 404 or a 422, for the reason
            # `academics.list_course_units` gives: the client filtered on a
            # value it believed exists -- a unit deleted, one at another
            # institution, or one in another faculty -- and the honest answer to
            # "tutors for this unit" is none. A refusal would put the discovery
            # screen into an error state over a stale picker value, which is
            # something the student did not do and cannot fix from here.
            return []

    threshold = await _competency_threshold(db, user.university_id)
    rows = await _ranked_tutors(
        db, user=user, threshold=threshold, scope=scope, limit=limit
    )
    if not rows:
        return []

    # One aggregate for the whole page rather than one per row: the rail is
    # rendered as a list, and a per-tutor query would make its cost a function
    # of how long the list is.
    counts = await rating_service.load_unit_endorsement_counts(
        db, [tutor.id for tutor, _profile, _count in rows]
    )

    entries: list[TutorRailEntry] = []
    for tutor, profile, endorsement_count in rows:
        endorsed = counts.get(tutor.id, [])
        entries.append(
            TutorRailEntry(
                user_id=tutor.public_id,
                # `User.display_name`, not a fallback written out here: `full_name`
                # is nullable by design (a student can hold an account they have
                # not named), and a deleted tutor has neither a name nor an
                # address worth showing. One definition covers all three.
                full_name=tutor.display_name,
                standing=profile.standing,
                # Read through the model rather than recomputed here, so the rail
                # shows the same `Decimal` the promotion rule was applied with.
                average_rating=profile.average_rating,
                completed_sessions=profile.completed_sessions,
                endorsed_course_unit_ids=[
                    row.course_unit_id for row in endorsed[:RAIL_ENDORSED_UNITS]
                ],
                endorsement_count=endorsement_count,
            )
        )
    return entries


async def get_tutor_detail(
    db: AsyncSession,
    user: User,
    tutor_public_id: uuid.UUID,
) -> TutorDetailResponse:
    """One tutor's student-facing profile, for the detail screen.

    A 404 covers both "no such user" and "that user is not a tutor". They are
    the same answer on purpose: a tutor list a student cannot reach is not
    something they are entitled to learn about by asking, and a route that
    distinguished them would confirm which accounts exist.

    `TutorProfile` is the test rather than the role table, for the reason the
    rest of the package treats that row as authoritative -- it exists for a
    tutor and for nobody else -- and because standing is a property of the row.

    Not scoped to the caller's university, and not excluding the caller. The
    university boundary is on discovery: the rail only ever proposes a tutor at
    the student's own institution. Every field here is one the rail already
    carries, so answering it for a tutor found elsewhere leaks nothing new, and
    refusing would make a shared link from a classmate unopenable. A suspended
    tutor *is* answerable, with the suspended standing visible, because a
    student who booked them has to find out.
    """
    result = await db.execute(
        select(User, TutorProfile)
        .join(TutorProfile, TutorProfile.user_id == User.id)
        .where(User.public_id == tutor_public_id)
    )
    row = result.first()
    if row is None:
        raise NotFoundProblem("That tutor could not be found.")

    tutor, profile = row
    counts = await rating_service.load_unit_endorsement_counts(db, [tutor.id])
    endorsed = counts.get(tutor.id, [])
    return TutorDetailResponse(
        profile=TutorProfileSummary(
            user_id=tutor.public_id,
            full_name=tutor.display_name,
            standing=profile.standing,
            average_rating=profile.average_rating,
            completed_sessions=profile.completed_sessions,
        ),
        endorsed_course_unit_ids=[
            entry.course_unit_id for entry in endorsed[:RAIL_ENDORSED_UNITS]
        ],
        endorsement_count=sum(entry.endorsement_count for entry in endorsed),
    )


async def _ranked_tutors(
    db: AsyncSession,
    *,
    user: User,
    threshold: Decimal,
    scope: CourseUnit | None,
    limit: int,
) -> list[tuple[User, TutorProfile, int]]:
    """The eligible tutors for the rail, in the order the rail shows them.

    Two derived tables rather than joins onto the base tables, because both of
    them are many-to-one and joining them directly would multiply rows: a tutor
    with three qualifying competencies and four endorsements would otherwise
    arrive twelve times, and the endorsement count would be the sum of that
    product rather than the number of endorsements they have.
    """

    # Eligibility is a membership question -- "does this tutor hold at least one
    # verified competency that clears the bar" -- so it is answered as `DISTINCT`
    # user ids rather than as rows. `DISTINCT` is what makes the join below
    # duplicate-free.
    eligible = (
        select(Competency.user_id.label("user_id"))
        .join(Grade, Grade.id == Competency.grade_id)
        .where(
            Competency.status == CompetencyStatus.VERIFIED,
            Grade.grade_points >= threshold,
        )
        .distinct()
    )
    if scope is not None:
        eligible = eligible.where(Competency.course_unit_id == scope.id)
    eligible_ids = eligible.subquery()

    counts = (
        select(
            UnitEndorsement.ratee_id.label("ratee_id"),
            func.count(UnitEndorsement.id).label("endorsement_count"),
        )
        .group_by(UnitEndorsement.ratee_id)
        .subquery()
    )
    # `coalesce` rather than a null ordering rule, because an outer join leaves
    # a tutor with no endorsements NULL, and `NULLS LAST` is not what `DESC`
    # means by default on every backend -- PostgreSQL puts nulls *first* on a
    # descending sort and SQLite puts them last. A zero here is not a claim,
    # it is the arithmetic meaning of no rows.
    endorsement_total = func.coalesce(counts.c.endorsement_count, 0)

    # The average is not a column: `TutorProfile.average_rating` derives it from
    # a stored total and count precisely so the division is never accumulated
    # rounding error. This expression is the same formula, written out because
    # SQL cannot call a Python property, and it exists only to *order* rows --
    # the value that reaches the client is read back off the model.
    average_rating = TutorProfile.rating_total / func.nullif(
        TutorProfile.rating_count, 0
    )

    result = await db.execute(
        select(
            User,
            TutorProfile,
            endorsement_total.label("endorsement_count"),
        )
        .join(TutorProfile, TutorProfile.user_id == User.id)
        .join(eligible_ids, eligible_ids.c.user_id == User.id)
        .outerjoin(counts, counts.c.ratee_id == User.id)
        .where(
            # The caller is not a browsing candidate. They know what they look
            # like, and a rail is a shortlist of other people.
            User.id != user.id,
            User.university_id == user.university_id,
            # The faculty silo. A tutor from another faculty teaches units the
            # student cannot ask for help with, so listing them is offering a
            # conversation that has no course to happen in. Compared as an
            # equality rather than filtered in the subquery above, because this is
            # a property of the person rather than of a competency, and an account
            # with no faculty compares unequal to everything -- which is the
            # answer we want for a student who has not finished onboarding.
            User.faculty_id == user.faculty_id,
            TutorProfile.standing != TutorStanding.SUSPENDED,
        )
        .order_by(
            endorsement_total.desc(),
            # Nulls last, stated: an unrated tutor is not the worst tutor on the
            # rail, they are the one with no evidence, and ranking them below a
            # 4.9 average would be reading absence as a score.
            average_rating.desc().nulls_last(),
            TutorProfile.completed_sessions.desc(),
            # The name as displayed, so the tiebreak is the order a student
            # reads. `coalesce` because `full_name` is nullable and both
            # backends disagree about where a null sorts in an ascending sort.
            func.coalesce(User.full_name, User.email).asc(),
        )
        .limit(limit)
    )
    return [(row.User, row.TutorProfile, row.endorsement_count) for row in result.all()]


async def _competency_threshold(db: AsyncSession, university_id: uuid.UUID) -> Decimal:
    """The lowest grade points that make a tutor eligible at this university.

    Read from the university's scale rather than hardcoded, because "B+" is a
    different number on a four-point, five-point, and percentage scale. A
    university with no published scale gets zero, which is the same answer
    `matching_service` gives: the two surfaces must not disagree about who is
    eligible, and the pilot seeds a scale for every institution.
    """
    scale_id = await db.scalar(
        select(University.grading_scale_id).where(University.id == university_id)
    )
    if scale_id is None:
        return Decimal("0")
    minimum = await db.scalar(
        select(GradingScale.competency_min_points).where(GradingScale.id == scale_id)
    )
    return minimum if minimum is not None else Decimal("0")


async def _load_course_unit(
    db: AsyncSession, public_id: uuid.UUID
) -> CourseUnit | None:
    """The course unit a public id names, or `None`.

    `None` rather than a 404, so the caller decides what an unknown filter means.
    """
    return await db.scalar(select(CourseUnit).where(CourseUnit.public_id == public_id))
