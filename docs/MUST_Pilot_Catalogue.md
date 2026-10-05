# MUST pilot catalogue

## Status

This is the **provisional engineering catalogue** for the closed MUST pilot.
It is not a complete MUST curriculum and does not represent institutional
approval. The pilot must not advertise a unit as available until MUST confirms
the launch list and participating tutor cohort.

The seed currently exposes only the six existing course-unit records below.
They are the initial technical candidates because they have real unit codes and
names in the repository. Programme names are not converted into course units:
a programme such as Computer Science is a degree programme, while a course unit
such as BIT 221 is a matchable learning unit.

## Provisional launch candidates

| Faculty | Code | Course unit |
| --- | --- | --- |
| Faculty of Computing and Informatics Sciences | BIT 221 | Operating Systems |
| Faculty of Computing and Informatics Sciences | BIT 223 | Database Programming |
| Faculty of Computing and Informatics Sciences | BIT 225 | Computer Networks |
| Faculty of Science | SCH 211 | Organic Chemistry |
| Faculty of Science | PHY 212 | Thermodynamics |
| Faculty of Science | MTH 213 | Linear Algebra |

## Faculties with no course units

Six faculties are seeded and only two of them — Computing and Informatics
Sciences, and Science — publish any course units. The other four are present so
that a student can choose the faculty they actually study in, and they answer
with nothing:

| Faculty | Course units |
| --- | --- |
| Faculty of Applied Sciences and Technology | none seeded |
| Faculty of Interdisciplinary Studies | none seeded |
| Faculty of Business and Management Sciences | none seeded |
| Faculty of Medicine | none seeded |

This is a normal state for the pilot, not a data fault, and the app is built for
it. For a student of one of these faculties:

- `GET /v1/academics/course-units` returns `[]`.
- The tutor rail returns `[]` — there are no units, so there is nothing to match
  and no tutor holds a competency for a unit these faculties do not teach.
- Onboarding still completes. The module step explains that the faculty has
  published nothing and lets the student finish with nothing chosen, because a
  gate that required a declared unit would return such a student to the wizard on
  every launch, for ever, with nothing they could do about it.

A student cannot reach the app by picking a faculty with no units; the four rows
are there so the picker offers the faculty the student actually belongs to rather
than only the two that happen to have content.

Before launch, MUST operations must supply the units for these faculties, or the
pilot has no launch list for a large share of its own students. That is item 1 of
the process below and it applies to every faculty, not just this table.

## Approval and change process

Before pilot invitations are issued, MUST operations must provide:

1. The exact course-unit list to make available.
2. The academic owner or source for each listed unit.
3. The initial tutor cohort and the units each tutor may support.

Engineering may update the seed with confirmed units, but must not invent unit
codes or infer them from faculty/programme descriptions. Any unconfirmed row
must remain clearly provisional or be removed from the launch seed.

The source of this data is `backend/app/db/seed.py`; running
`python -m app.db.seed` is idempotent and does not remove existing rows.
