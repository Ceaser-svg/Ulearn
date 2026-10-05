# MUST pilot catalogue

## Status

This is the **provisional engineering catalogue** for the closed MUST pilot.
It is not a complete MUST curriculum and does not represent institutional
approval. The pilot must not advertise a unit as available until MUST confirms
the launch list and participating tutor cohort.

Every faculty the seed publishes carries at least one course unit. That is a
product requirement, not tidiness: a student can only declare a primary module
that exists, a declared module is the only route to the tutor rail, and applying
to tutor needs a unit to submit proof against. A faculty with an empty catalogue
would lock out every student who chose it, and the app could not tell them so.

## Provisional launch candidates

| Faculty | Code | Course unit |
| --- | --- | --- |
| Faculty of Computing and Informatics Sciences | BIT 221 | Operating Systems |
| Faculty of Computing and Informatics Sciences | BIT 223 | Database Programming |
| Faculty of Computing and Informatics Sciences | BIT 225 | Computer Networks |
| Faculty of Science | SCH 211 | Organic Chemistry |
| Faculty of Science | PHY 212 | Thermodynamics |
| Faculty of Science | MTH 213 | Linear Algebra |
| Faculty of Medicine | MED 211 | Human Anatomy |
| Faculty of Medicine | MED 212 | Human Physiology |
| Faculty of Medicine | MED 213 | Medical Biochemistry |
| Faculty of Applied Sciences and Technology | AST 211 | Electrical Circuits |
| Faculty of Applied Sciences and Technology | AST 212 | Electronics |
| Faculty of Applied Sciences and Technology | AST 213 | Engineering Drawing |
| Faculty of Business and Management Sciences | BMS 211 | Financial Accounting |
| Faculty of Business and Management Sciences | BMS 212 | Principles of Economics |
| Faculty of Business and Management Sciences | BMS 213 | Entrepreneurship |
| Faculty of Interdisciplinary Studies | IDS 211 | Planning and Governance |
| Faculty of Interdisciplinary Studies | IDS 212 | Human Development and Relational Sciences |
| Faculty of Interdisciplinary Studies | IDS 213 | Community Engagement and Service Learning |

### The first six rows are placeholders

`BIT 221`, `SCH 211`, `PHY 212` and `MTH 213` are pre-existing seed entries that
have no institutional source either. They were written before any MUST data was
available and exist only to give the matching and tutor flows something to
exercise. Treat them as placeholders on the same footing as the twelve rows below.

### Where the twelve new rows come from

**MUST does not publish a course-unit catalogue.** `must.ac.ug` programme pages
carry faculty, course code, duration, fees and entry requirements, but their
"Course Modules" tab is empty, and no module list is published anywhere public.
There was therefore no official code to copy, and **every code in this table is
provisional** — a faculty prefix plus a three-digit number following the existing
`BIT 221` shape, not a MUST course code.

The *names* are sourced, and taken from MUST's own academic units — the
departments each faculty page lists — rather than from programme names. A
department is a real, verifiable academic unit and its subject areas are what its
early courses teach; a degree programme is not a course unit.

| Faculty | Source | Departments taken from |
| --- | --- | --- |
| Faculty of Medicine | `must.ac.ug/university_unit/faculty-of-medicine`, and its Biochemistry department page, which states biochemistry is "a mandatory course for all students in the faculty" | Anatomy, Physiology, Biochemistry |
| Faculty of Applied Sciences and Technology | `must.ac.ug/university_unit/faculty-of-applied-sciences-and-technology`, plus the BEEE programme page whose entry requirements name Technical Drawing | Department of Electrical and Electronic Engineering |
| Faculty of Business and Management Sciences | `must.ac.ug/university_unit/faculty-of-business-and-management-sciences` | Department of Accounting and Finance; Department of Economics and Entrepreneurship |
| Faculty of Interdisciplinary Studies | `must.ac.ug/university_unit/faculty-of-interdisciplinary-studies` | Department of Planning and Governance; Department of Human Development and Relational Sciences; Department of Community Engagement and Service Learning |

Retrieved for this seed. When MUST supplies the real catalogue, replace the whole
table: nothing outside `backend/app/db/seed.py` encodes a code or a name.

### Faculty naming drift, not corrected here

MUST's own site now calls this faculty **"Faculty of Health Sciences"** (its URL
still says `faculty-of-medicine`) and lists a seventh faculty, **Agriculture,
Environment and Veterinary Sciences (FAEVS)**, which the seed does not have. The
seed keeps the older names: renaming a seeded faculty would orphan every course
unit, declared module and competency keyed to it. Reconciling this is a
migration and a product decision, not a seed edit — raise it before launch.

## A university whose catalogue is not loaded

Every *seeded* faculty has a unit now, but a university publishing none is still
an ordinary state, and the app is built for it:

- `GET /v1/academics/course-units` returns `[]`, and the tutor rail returns `[]`.
- Onboarding still completes. The module step explains that the faculty has
  published nothing and lets the student finish with nothing chosen, because a
  gate that required a declared unit would return such a student to the wizard on
  every launch, for ever, with nothing they could do about it.

This is covered by staging a second university with no units
(`test_a_faculty_with_no_course_units_is_offered_none`) rather than by leaving a
seeded faculty empty, and by `test_every_seeded_faculty_offers_at_least_one_unit`,
which fails if a faculty is added without a unit.

## Approval and change process

Before pilot invitations are issued, MUST operations must provide:

1. The exact course-unit list to make available.
2. The academic owner or source for each listed unit.
3. The initial tutor cohort and the units each tutor may support.

### On invented codes

Engineering must not invent a course code and present it as a real one. Two
provisional uses are allowed, and both must stay labelled as such in
`backend/app/db/seed.py`:

- **A placeholder** for a unit no data exists for, so that a feature has
  something to exercise. `BIT 221` and the Science rows are these.
- **A provisional code with a sourced name**, as the twelve Medicine, FAST,
  business and interdisciplinary rows are. The *name* is taken from a real MUST
  department because that is verifiable today; the *code* has no source because
  MUST publishes none, so it is labelled provisional rather than guessed at.

What is not allowed is a code that reads as authoritative. When MUST supplies the
real catalogue, replace the table wholesale. Any row that has not been confirmed
by MUST must keep its provisional marking in the seed, and must not be advertised
as available in the pilot.

The source of this data is `backend/app/db/seed.py`; running
`python -m app.db.seed` is idempotent and does not remove existing rows.
