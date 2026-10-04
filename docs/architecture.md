# PeerPass Architecture

**System Design & Technical Blueprint**

> This document describes the high-level architecture, core components, data model, matching engine, and validation protocol of PeerPass — a peer-to-peer academic support network for university students.

**Last Updated**: September 2026 | **Status**: Active

---

## 1. Vision & Design Goals

PeerPass exists to replace the “attend lectures and fight for your life” model with a reliable, stigma-free micro-intervention safety net. The architecture is shaped by the following goals:

| Goal                        | Architectural Implication                                                           |
| --------------------------- | ----------------------------------------------------------------------------------- |
| Mobile-first, low-bandwidth | Flutter client; lightweight API payloads; offline-friendly patterns where practical |
| Academic integrity          | Multi-tier tutor validation before matching is allowed                              |
| Low friction for students   | Simple request → match → session flow                                               |
| Verifiable incentives       | Session logging that can generate Teaching Assistant certificates                   |
| Institutional readiness     | PostgreSQL relational model, SSO-ready auth, DPPA-compliant data handling           |
| Future LMS integration      | Clean API boundaries and modular services                                           |

---

## 2. High-Level System Overview

```
┌─────────────────┐         HTTPS / REST          ┌──────────────────────┐
│                 │  ◄──────────────────────────► │                      │
│  Flutter App    │                               │   FastAPI Backend    │
│  (Mobile)       │                               │                      │
│                 │                               │  • Auth & Users      │
└─────────────────┘                               │  • Matching Engine   │
                                                  │  • Validation        │
                                                  │  • Sessions & Ratings│
                                                  │  • Incentives        │
                                                  └──────────┬───────────┘
                                                             │
                                                             │ SQLAlchemy
                                                             ▼
                                                  ┌──────────────────────┐
                                                  │    PostgreSQL        │
                                                  │                      │
                                                  │  Users               │
                                                  │  Course_Units        │
                                                  │  Competencies        │
                                                  │  Help_Requests       │
                                                  │  Sessions            │
                                                  │  Ratings             │
                                                  └──────────────────────┘
```

**Key characteristics**

- Client-server architecture with a shared Flutter student client for mobile and web,
  plus a separate responsive Flutter web admin console
- Stateless REST API (FastAPI) for all business logic
- Relational database as the source of truth for users, competencies, and sessions
- Matching and validation logic live in dedicated backend services (not in the client)

---

## 3. Technology Stack

| Layer                | Technology                  | Rationale                                                                                                    |
| -------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **Frontend**         | Flutter                     | Cross-platform (Android + iOS), excellent performance on modest devices, strong offline capabilities         |
| **Backend**          | FastAPI (Python 3.10+)      | High performance, automatic OpenAPI docs, excellent async support, rapid development                         |
| **ORM / Migrations** | SQLAlchemy + Alembic        | Mature, type-friendly, reliable schema evolution                                                             |
| **Database**         | PostgreSQL                  | Strong relational integrity, excellent for complex joins (matching + competencies), JSON support when needed |
| **Auth**             | JWT + future University SSO | Stateless tokens for mobile; designed for institutional SSO integration                                      |
| **API Style**        | RESTful JSON                | Simple, cacheable, easy to consume from Flutter                                                              |

---

## 4. Core Components

### 4.1 Frontend (Flutter)

Organized in a **feature-first** structure:

- `auth` — Registration, sign-in, and the onboarding wizard
- `home` — The signed-in Home tab for matching and active-session discovery
- `sessions` — The authenticated Sessions tab for active/past sessions and
  tutor-only request/certificate insights
- `profile` — The authenticated Profile tab for account information, roles,
  sign-out, and account deletion
- `matching` — Create topic requests, view candidates, select or decline matches
- `tutor_validation` — Declare competency evidence and view verification status
- `incentives` — View logged hours and certificate eligibility
- `admin_web` — Responsive MUST operations console for users, competencies,
  tutor standing, and append-only audit events

Shared layers:

- Network client (Dio), failures, and RFC 9457 translation
- Riverpod for state management
- Core theme, constants, and reusable widgets

#### Session state lives in `core/`, not in `auth`

`frontend/lib/core/state/session.dart` holds the one source of truth for who is
signed in. This is not a layering preference, it is forced by two rules in
`AGENTS.md`: a feature must never import another feature's `presentation/`, and
`core/` must never import from `features/`.

Home has to know who is signed in, and the router has to decide where a session
belongs. If the session lived in `auth`'s presentation layer, both would be
either an illegal import or a rule exception. Promoting it to `core/` gives one
place that auth writes and that the router and every feature can read, with no
rule changed. `UserProfile` moved to `core/models/` for the same reason — it is
consumed by several features, so a feature-local home for it was always going to
be wrong.

The consequence worth stating: `AuthController` no longer holds state. It
performs repository calls and records the outcome in the core session, so there
is exactly one `SessionState` and no second copy to fall out of step.

#### The repository provider is declared with the contract

`authRepositoryProvider` is declared in
`frontend/lib/features/auth/data/repositories/auth_repository.dart`, not in the
feature's presentation layer. A provider declared in `presentation/` could not be
imported by a sibling feature without dragging that feature's screens along, so
the handle has to sit beside the interface it hands out.

This is the one cross-feature import the architecture permits, and home's
sign-out uses it (`features/home/presentation/providers/sign_out_controller.dart`):
it calls the auth repository contract and records the outcome in the core
session. `test/architecture/dependency_rules_test.dart` enforces exactly this
line — another feature's `presentation/` is forbidden, its repository contract
is not.

#### Composition happens in `main.dart`, once

`lib/main.dart` is a real composition root: `AppConfig`, `SecureTokenStore`,
`RemoteAuthRepository`, and the remote datasources are built there and overridden
into `ProviderScope`. There is no in-memory default on the request path, so a
stub cannot hide behind a working screen.

#### Validation is deliberately duplicated

`frontend/lib/core/utils/validators.dart` repeats the server's rules rather than
the server being the only enforcer. The server stays the authority; the client
checks only to spare a round trip and to put a message under the input that
caused it. A client-side rule that drifts from the server is a cosmetic bug, not
a security hole.

#### Animations are native and finite

Splash, sign-in, sign-up, and the consent tick are custom-painted. No Rive, no
animation package, no image assets. They are also finite rather than looping, so
`pumpAndSettle()` terminates in a widget test and the app is not burning a
timeline forever behind a static screen. All of them respect
`MediaQuery.disableAnimations`.

### 4.2 Backend (FastAPI)

Layered structure:

```
api/          → HTTP routes & request validation
services/     → Business logic (matching, validation, incentives)
models/       → SQLAlchemy ORM models
schemas/      → Pydantic request/response models
core/         → Config, security, database session, exceptions
```

**Critical services**

- `MatchingService` — Core algorithm that pairs tutee requests with eligible tutors
- `ValidationService` — Implements the three-tier tutor quality gate
- `TutorService` — The discovery rail and one tutor's public profile
- `SessionService` — Lifecycle of a tutoring session + logging
- `IncentiveService` — Aggregates hours and prepares certificate data
- `AdminService` — Least-privilege MUST operations and append-only audit records

Administrative access is a separately provisioned `admin` role in the existing
role join table. The API fails closed through one dependency before reaching an
admin route. Admin responses use dedicated schemas rather than student-facing
schemas, so passwords, refresh tokens, consent timestamps, competency evidence,
and internal ids cannot be exposed by adding a field to a shared response.

`app/services/` is a package of public functions, and a route calls one of them.
No router reaches for a `_`-prefixed name: reaching into another module's internals
works until the thing it points at is renamed, and the matching router was doing it
for two of them. The ownership check and the response shape of a help request are
one decision, which is why they are one public function rather than two internals
a route could mix and match.

### 4.3 Database (PostgreSQL)

Primary tables (see Section 5 for details):

| Table               | Responsibility                                                   |
| ------------------- | ---------------------------------------------------------------- |
| `users`             | Identity and contact details; roles live in the `user_roles` join |
| `user_roles`        | A user's roles, which may be several (`student` and `tutor`)      |
| `refresh_tokens`    | Hashed refresh-token handles, for rotation and reuse detection    |
| `universities`      | Institution a user and course unit belong to                       |
| `grading_scales`    | An institution's scale and its competency threshold               |
| `grades`            | The grade catalogue for a scale                                   |
| `subjects`          | Faculty or department grouping for course units                   |
| `course_units`      | University curriculum mapping                                     |
| `competencies`      | Tutor eligibility per course unit (grade + verification status)   |
| `tutor_profiles`    | A tutor's standing and the counters it is derived from            |
| `help_requests`     | What a student asked for, before any tutor was matched            |
| `sessions`          | A tutoring session that actually took place                       |
| `ratings`           | Post-session feedback that drives tutor promotion / demotion     |

### 4.4 Transport Schemas (`backend/app/schemas/`)

Pydantic v2 models, separated from the ORM, so the wire contract can change
without a migration and the tables can change without a client release.

Two base types carry the whole policy:

- `RequestSchema` — `extra="forbid"`. A misspelled field is an error rather than
  a silent drop, because a `rating` sent as `score` would otherwise create a
  rating with no score.
- `OrmSchema` — `from_attributes`, `frozen`, `populate_by_name`.

**Internal keys never reach the wire.** A response field named `id` is populated
from the model's `public_id` through `validation_alias`, and a referenced
resource is named the same way:

| Response field          | Read from                      |
| ----------------------- | ------------------------------ |
| `id`                    | `public_id`                    |
| `course_unit_id`        | `course_unit_public_id`        |
| `university_id`         | `university_public_id`         |
| `grading_scale_id`      | `grading_scale_public_id`      |
| `user_id` (tutor)       | `user.public_id`               |

This is not a convention to remember, it is a test:
`backend/tests/schemas/test_public_id_projection.py` resolves every alias
against the real mapped class and fails on a `*_id` field that has no alias —
which is the shape of a primary key quietly shipping to a client.

**Not every response can be built straight from a query.** These fields need a
service, and the test file lists them so each one is a deliberate edit:

| Field                  | Why                                                        |
| ---------------------- | ---------------------------------------------------------- |
| `UserResponse.roles`   | `user_roles` is an association table, not a relationship   |
| `SessionResponse.is_rated` | `Session.is_rated(db)` is an async query hook           |
| `CompetencyResponse.meets_threshold` | A method taking the threshold, not a field |
| `CompetencyResponse.grade_points`    | Computed in the service                 |
| `TutorRailEntry.user_id` / `TutorProfileSummary` in a rail row | No model carries a tutor's user id as its *public* id, so an unaliased field handed a `TutorProfile` would quietly become its primary key. Both are built by keyword by the service from `User.public_id`. |

**Decimals cross the wire as JSON strings.** Pydantic's default, kept
deliberately: a JSON number is a double in Dart, and a double cannot represent
every `numeric(6,2)` value, so `rating_total` is `"18.00"` and not `18.0`. The
client parses it for display; every threshold comparison happens server-side
against the `Decimal`.

**A mean is rounded at the edge, and only at the edge.**
`app.schemas.base.MeanRating` rounds `average_rating` half-up to the two decimal
places the schemas declare. A mean need not fit in two places — eight ratings
totalling 33 average 4.125 — and Pydantic v2 validates rather than rounds, so the
exact value raised a validation error and the endpoint answered 500 for any tutor
whose ratings did not divide evenly. `TutorProfile.average_rating` stays exact on
purpose: promotion is an equality test on it, and rounding there would promote a
tutor averaging 3.999 and demote one averaging 4.004. Rounding is a wire
decision, never a product one.

**Trimming is per field, not per model.** `app.schemas.base.Trimmed` is applied
to names, topics, and feedback, and deliberately *not* to passwords, whose
leading and trailing spaces are part of the secret.

---

## 5. Data Model

### 5.1 Entity Relationships (Conceptual)

```
Universities 1 ─── * Grading_Scales 1 ─── * Grades
      │ 1                │ 1
      │                  │
      │ *                │
Course_Units * ─────────┘ (grade)
      │ *
      │ 1
      │
Users 1 ─── * Competencies
  │ 1
  │
  ├── 1 Tutor_Profiles
  ├── * Help_Requests * ─── * Sessions * ─── * Ratings
  └── * Refresh_Tokens
```

`help_requests` and `sessions` are separate tables on purpose. A request that is
never matched must not leave a session row behind, or every tutor workload query
carries a filter for sessions that never happened.

### 5.2 Schema Highlights

| Table             | Core Attributes                                                | Purpose                                                                                |
| ----------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Users**         | `id`, `public_id`, `email`, `full_name`, `university_id`, `faculty_id`, `year_of_study` | Identity. Roles live in `user_roles`, because one user may be both student and tutor. `full_name` is **nullable**: an account exists between sign-up and the end of onboarding, and requiring a name at registration would put four fields on the sign-up form to get the same result — the first one lost is a student who abandons it |
| **User_Roles**    | `user_id`, `role`                                              | Join table; composite primary key stops a role being held twice                         |
| **Tutor_Profiles**| `user_id`, `standing`, `rating_total`, `rating_count`, `certified_minutes` | Aggregate standing, stored rather than recomputed per matching query          |
| **Grading_Scales**| `max_points`, `competency_min_points`                          | The B+ bar as data, since pilot institutions disagree on what B+ means                 |
| **Grades**        | `label`, `grade_points`, `grading_scale_id`                    | Grade catalogue; one label per scale                                                    |
| **Course_Units**  | `code`, `name`, `university_id`, `subject_id`, `grade_id`      | Maps the exact university curriculum                                                    |
| **Competencies**  | `user_id`, `course_unit_id`, `grade_id`, `status`, `source`    | Validation gate requiring a verified grade at or above the scale's threshold            |
| **Refresh_Tokens** | `id` (PK), `user_id` (FK → users), `token_hash` (unique), `expires_at`, `revoked_at`, `replaced_by_id` (FK → refresh_tokens, optional) | The handle is a JWT; only its peppered hash is stored, so a database disclosure yields no usable token. `replaced_by_id` forms the chain that makes reuse of an already-rotated token detectable. Every row is deleted on user deletion |

##### Faculties and programs are university-scoped

`users.faculty_id` and `course_units.subject_id` point at `subjects`, and each
seeded subject belongs to one university. Faculty names are unique within a
university rather than globally, so two institutions may both have a Faculty of
Science without sharing a catalogue. `GET /v1/academics/faculties` therefore
requires the selected university.

Degree and postgraduate offerings are stored as `programs`, linked to both the
university and faculty. Programs describe what an institution offers; course
units remain the specific records used by help requests, competencies, and
matching. This prevents a degree name such as Medicine and Surgery from being
mistaken for a matchable course unit.

**Help_Requests** | `tutee_id`, `course_unit_id`, `topic`, `status`                | What was asked for, before a tutor was matched                                          |
| **Sessions**      | `tutee_id`, `tutor_id`, `course_unit_id`, `status`, `duration_minutes`, `session_pin`, `meeting_link` | A session that happened; the source for tutor hours and certificates. Holds the handshake PIN and copyable meeting link; the PIN is tutor-revealed and tutee-entered, so it is never in a shared response |
| **Ratings**       | `session_id`, `rater_id`, `ratee_id`, `score`, `feedback_text` | Post-session feedback; low ratings reduce matching priority. `rater_id` and `ratee_id` are both set, because either party may rate a completed session, but only the session's **tutor** has a `Tutor_Profile` to update — see 8.2 |
| **Unit_Endorsements** | `session_id`, `rater_id`, `ratee_id`, `course_unit_id` | "This tutor knows this unit", scoped to the session's own course unit. Separate from `ratings` so subject coverage never moves promotion. Unique on `(session_id, rater_id, course_unit_id)` so a corrected submission replaces rather than accumulates |

### 5.3 Detailed Table Definitions

Every table uses a UUIDv7 `id` primary key and a separate UUIDv4 `public_id` for
the wire. The primary key is time-ordered so inserts land at the end of the write
index; the public id is random so it encodes nothing about creation time.

**Users**

- `id` (PK), `public_id` (unique)
- `email` (unique), `full_name`, `password_hash`
- `university_id` (FK → universities, optional)
- `is_active`
- `academic_data_consented_at` — records the academic-data consent the Uganda
  Data Protection and Privacy Act requires before a transcript is processed
- Roles are **not** a column. See `user_roles`.

**User_Roles**

- `user_id` (FK → users), `role` — `student` | `tutor`
- Composite primary key on (`user_id`, `role`)

Administrator access is an explicit `admin` role provisioned outside the public
registration flow,
and a role that grants it would need audit logging attached before it is worth
having; adding the string to the enum now would make it look implemented.

**Universities**

- `id` (PK), `name` (unique)
- `grading_scale_id` (FK → grading_scales) — required before a tutor at this
  institution can be matched

**Grading_Scales**

- `id` (PK), `name` (unique), `max_points`
- `competency_min_points` — the lowest grade that makes a tutor eligible, in
  this scale's points
- CHECK: `0 < competency_min_points <= max_points`

**Grades**

- `id` (PK), `label`, `grade_points`, `max_points`
- `grading_scale_id` (FK → grading_scales)
- Unique on (`grading_scale_id`, `label`)
- CHECK: `0 < grade_points <= max_points`
- `max_points` is denormalised from the scale so the CHECK above can be enforced
  by the database, which cannot compare across tables. Rescaling a published
  scale must rescale its grades in the same transaction.

**Subjects**

- `id` (PK), `name` (unique)
- A faculty or department grouping. Distinct from a course unit: matching widens
  from a unit to its subject, so a tutor can be competent across several units.

**Course_Units**

- `id` (PK), `code`, `name`, `description`
- `university_id` (FK → universities) — **required**
- `subject_id` (FK → subjects), `grade_id` (FK → grades), both optional
- Unique on (`university_id`, `code`)

`university_id` is required because a composite unique index treats NULLs as
distinct, so a nullable university would let two unscoped units share a code. It
is also required by matching, which only pairs people at one institution.
Scoping the code is what lets `MAT 221` exist at two universities as two
different courses, graded on two different scales.

**Competencies**

- `id` (PK)
- `user_id` (FK → users), `course_unit_id` (FK → course_units)
- `grade_id` (FK → grades)
- `status` — `pending` | `verified` | `rejected`
- `source` — `transcript` | `portfolio` | `manual`
- `reviewed_by_id` (FK → users), `verified_at`, `rejection_reason`,
  `evidence_reference`
- Unique on (`user_id`, `course_unit_id`)

Both `user_id` and `reviewed_by_id` point at `users`, so the ORM relationships
must name their foreign key explicitly. A pending competency never meets the
threshold, whatever grade it carries: a grade is a claim until checked.

**Tutor_Profiles**

- `id` (PK), `user_id` (FK → users, unique)
- `standing` — `probationary` | `verified` | `reduced` | `suspended`
- `completed_sessions`, `certified_minutes`
- `rating_total`, `rating_count` — a running total and a count, not a stored
  average, so promotion does not accumulate rounding error on an equality test
- `suspended_reason`

**Help_Requests**

- `id` (PK)
- `tutee_id` (FK → users), `course_unit_id` (FK → course_units)
- `topic`, `description`
- `status` — `open` | `matched` | `withdrawn` | `expired`
- `matched_tutor_id` (FK → users, optional)

**Sessions**

- `id` (PK)
- `tutee_id`, `tutor_id` (FK → users) — CHECK: `tutee_id <> tutor_id`
- `course_unit_id` (FK → course_units), `help_request_id` (FK → help_requests,
  optional and unique)
- `topic`, `scheduled_start`, `started_at`, `ended_at`, `duration_minutes`
- `status` — `scheduled` | `in_progress` | `completed` | `cancelled` | `no_show`
- `cancelled_by_id` (FK → users), `cancellation_reason`
- CHECK: `duration_minutes >= 0`
- CHECK: a `completed` session has both `started_at` and `ended_at`, since
  otherwise the hours it contributes to a certificate are unknowable

**Ratings**

- `id` (PK)
- `session_id` (FK → sessions), `rater_id`, `ratee_id` (FK → users)
- `score` — CHECK: `1 <= score <= 5`
- `feedback_text`
- Unique on (`session_id`, `rater_id`), so a retried submit updates rather than
  averaging a second score in
- Used by the validation engine to promote or demote tutors

The rule that a completed session requires a rating spans two tables and cannot
be a CHECK constraint, which may only reference its own row. It is enforced in
the session service, and `Session.is_rated(db)` is the check it is written
against.

**Rate_Limit_Counters**

- `id` (PK), `public_id` (unique)
- `scope` — what is being counted: `auth.login.account`, `auth.login.ip`,
  `auth.register.ip`
- `key` — the thing counted within the scope: a normalised email address, or a
  client IP
- `attempts` — CHECK: `attempts >= 0`, `server_default` `0`
- `locked_until` — nullable; null means not locked
- Unique on (`scope`, `key`)

`scope` is part of the identity of the row rather than a label, so two scopes
cannot share a counter when their keys coincide — a student's email address is not
an IP address, but `"127.0.0.1"` is a legal local part and the two must not
collide. The unique constraint is load-bearing rather than decorative: it is the
`ON CONFLICT` target that makes the limiter's increment atomic. See 9.3.

`public_id` is unused — no endpoint returns this table — and is declared anyway
because every table in this codebase carries one.

---

## 6. Multi-Tiered Tutor Validation Protocol

A peer-to-peer system is only useful if tutors are competent. PeerPass enforces quality through three sequential gates:

### Tier 1 — Academic Data Gate (Hard Gate)

- Tutor must have a verified grade of **B+ or higher** in the target course unit.
- Source: uploaded transcript or secure institutional query.
- Without this, the user cannot be matched as a tutor for that unit.

### Tier 2 — External Portfolio Gate (Practical Gate)

- Optional override / enhancement for practical subjects.
- Examples: GitHub activity for software modules, deployed projects, etc.
- Allows provisional elevation when traditional grades under-represent skill.

### Tier 3 — Probationary Feedback Loop (Community Gate)

- New tutors start at standing `probationary`.
- Every completed session requires a rating from the tutee.
- High average rating → standing `verified` + leadership credits.
- Low average rating → standing `reduced` (lower matching priority) or
  `suspended` (revoked for that unit).

Standing lives in `tutor_profiles.standing`, not in the user's role. The role says
what a person may do; the standing says how much they are trusted. Collapsing the
two into one column, as the earlier draft did with `role_type`, would make a
suspension indistinguishable from a role change and would lose the per-unit
revocation this tier exists to express.

This logic lives in `ValidationService` and is consulted by `MatchingService` before any match is proposed.

---

## 7. Matching Engine

### High-Level Flow

1. A tutee submits a **topic request** (course unit + specific concept), or asks
   for tutors for a course unit directly.
2. One query runs over `competencies` joined to `user_roles`, keeping tutors who:
   - hold a **verified** competency for that course unit, at or above the
     university's `competency_min_points`
   - are at the caller's own university
   - are not `suspended`
   - have a `tutor_profiles` row to rank on
3. Ranking is by score: the competency's grade points, plus a tenth of the
   tutor's mean rating, plus `+2` for `verified` and `-1` for `reduced` standing.
4. Ties break on grade, then the tutor's displayed name, then the course unit's
   **code**. The code rather than the unit's public id, because a UUID is random:
   ordering by it is deterministic and meaningless, and it would stop a tutor in
   two units of one subject from ever holding the alphabetically first one.
5. The top candidates are presented to the tutee, who chooses. Nothing is
   auto-matched, and there is no availability model: nothing stops a tutor holding
   two sessions at once, which is why `already_booked` was removed from the
   exclusion codes rather than implemented.

The matching service is deliberately kept pure (no UI concerns) so it can later be
exposed to institutional dashboards or LMS plugins.

### 7.1 One query, two entry points

A help request and a course unit are the same question asked from two screens, so
there is one search and two routes over it: `/matching/suggestions` for a
course unit, and `/matching/help-requests/{id}/matches` for a request. A second
copy of the eligibility rules is a second copy to drift, and the two answers would
diverge exactly where a student is deciding.

The request in the path is the subject of the query, not a check in front of an
unrelated one. It used to load the request and then match whatever the body
carried, so a client asking "who can take *this* request" was answered about a
different course. A body naming a different unit is now a 422 rather than a
silent preference for one of the two: quietly choosing would leave a client
displaying results for a unit it did not ask about.

`MatchResponse.request_id` is `null` for the unit-only query and the request's own
public id for the request-backed one. The field names a help request the client
could go and open, so an id minted by a query that no request backs would be a
link to a 404.

### 7.2 A rule out is a code, not a silence

`MatchExclusion.reason` is a stable code drawn from `MATCH_EXCLUSION_REASONS`, and
the set is generated from that one constant, so the list a client is told it may
branch on cannot drift from what the engine emits. Drift is not cosmetic: an
advertised reason nothing produces leaves a client with a branch that never fires
and a tutor with a real, fixable problem told the platform has no reason.

Codes: `unverified`, `same_university_only`, `suspended`, `below_threshold`,
`not_the_tutor`. The order of the checks is the order above, and it is not
arbitrary: `unverified` is reported before any number is compared, so a tutor
with an unverified A is not told their problem was the grade. Pending
competencies are therefore read rather than filtered out — dropping the row
silently made the commonest reason for a tutor's absence unanswerable.

The caller is never a candidate for their own request, and is filtered in the
query rather than reported as an exclusion: they were never considered, so
"ruled out" would be a statement about them rather than about the rule.

### 7.3 One row per tutor, and one round trip

A widened search returns one candidate per tutor rather than one per competency,
keeping their strongest qualifying unit. A tutor competent in three units is one
suggestion, and listing them three times pushes three weaker tutors off a page the
student is choosing from.

The tutor role is resolved by joining `user_roles` in the same query. It was one
query per competency, so a widened search across a large subject cost a round trip
per row before producing the answer a single join gives. The result set cannot
reveal that — both versions return the same tutors — so
`tests/test_matching.py` asserts on the statement count with one tutor and then
with four, and requires it to be unchanged.

### 7.4 Tutor discovery is not matching

`GET /v1/tutors/top` and `GET /v1/tutors/{user_id}` answer "who is strong here",
which is a different question from "who may take this request". They share exactly
one rule — a verified grade at or above `competency_min_points` — and deliberately
nothing else:

- The rail **does not widen**. A discovery list that quietly substitutes a tutor
  from a different course is answering a question the student did not ask.
- The rail **ranks by endorsement count**, then mean rating, then completed
  sessions, then the displayed name. The name tiebreak is what makes the order
  stable rather than a function of the query plan.
- The rail is scoped to the caller's university and excludes the caller; the
  detail screen is scoped to neither, so a link a classmate shares still opens.
- A `suspended` tutor is excluded from the rail **in the query**, not filtered out
  afterwards, so a later filter added above it cannot leak one. The detail screen
  is the deliberate exception and shows the standing: a student who booked them
  has to be able to find out.
- Neither endpoint creates a `tutor_profiles` row. The row is created when the
  tutor role is granted; a browse that minted one would hand every signed-in
  student a `probationary` standing on every cold start.
- The competency bar applies on **both** paths, filtered and unfiltered. Every
  unit at one university is graded on that university's single scale, so applying
  it only when a unit was named would mean the same tutor passes in one query and
  fails in the other depending on which screen asked.

A well-formed `course_unit_id` that is unknown, or belongs to another university,
returns `[]` rather than an error. Same reasoning as
`GET /v1/academics/course-units`: the client filtered on a value it believed
existed, and a refusal would put a student's discovery screen into an error state
over a stale picker value.

The rail's endorsed-unit list is capped at `RAIL_ENDORSED_UNITS` and the full
total travels beside it. A tutor endorsed in fourteen units is not summarised by
any five of them, and the number shown has to be the whole truth for the sample
next to it to mean anything.

### 7.5 The decision is the student's, and the gate is re-derived

A proposed list is not a decision. The student names one tutor, that tutor
confirms or declines, and only a confirmation creates the session.

**Selection re-runs the search.** The named tutor is checked by asking the same
`_search_candidates` the matching answer came from and looking for them in the
result. Nothing is re-derived by re-reading the rules, because the rules are
where the drift would live: a second copy of the competency, grade, university
and standing checks is a second copy to maintain, and it would diverge exactly
when a student is deciding who to trust. Reachability is the question, not rank —
a tutor who passes the gate is acceptable even if a client that asked for a short
list would not have shown them, since `limit` is the caller's to choose and a
refusal justified by which page was scrolled to helps nobody.

`POST /v1/sessions` is a **confirmation, not a claim**, and the distinction is
load-bearing. It used to accept any tutor against any unselected request, setting
`matched_tutor_id` to the caller: a tutor could take work a student had refused
them, which is the inverse of the decision the platform exists to make. Only the
tutor the student already named may confirm, and only out of
`pending_confirmation`.

**Nothing expires.** There is no job closing an unanswered request. A request that
quietly expired would leave a student who applied and heard nothing, which is the
same silence as the platform losing it. `declined` is terminal for the mirror
reason — a request the tutor refused is not the same as one nobody was asked, and
re-opening it would let a tutor decline and then watch the student re-select them.
Recovery is a new request, which keeps the record of what was asked intact.

### 7.6 Where the confirmation screen lives

Confirmation is a session, so it lives in the sessions feature, and matching
navigates to it through `AppRoutes.confirmRequestPath` rather than importing
another feature's `presentation/`. The request id, unit id and topic travel as
route query values, URI-encoded — a topic is free text a student typed, and the
screen needs it to say what is being confirmed.

The waiting list is the mirror: it is matching's own screen, reached from home for
tutors only, and it navigates *out* to sessions the same way. Both directions cross
the boundary through the router, which is what the feature boundary is for.

The redirect guard has to know about both routes, or the entry navigates, the
guard undoes it, and the screen is unreachable in the app while green in tests.
That is not hypothetical: the guard had no entry for the waiting list, and every
widget test passed because they pumped the screen directly and never came through
the guard.

---

## 8. Session Lifecycle

```
Help Request Created (open)
      │
      ▼
Matching Engine proposes eligible tutors
      │
      ▼
Student selects one → pending_confirmation   (never expires)
      │
      ├── Tutor declines → declined            (terminal; recovery is a new request)
      │
      ▼
Tutor confirms → POST /v1/sessions
      │
      ▼
Session Scheduled (in-app)
      │
      ▼
PIN Handshake: tutor reveals a 2-digit PIN, tutee submits it
      │   (a missing PIN fails closed — never treated as a match)
      ▼
Session Completed  (status assigned first, then the accrual —
                   so minutes bank exactly once)
      │
      ▼
Rating Submitted → ValidationService updates tutor status
      │
      ▼
IncentiveService logs hours → certificate eligibility
```

### 8.1 The PIN handshake is attendance evidence

A two-digit PIN is weak as a secret and is not one. It exists to make attendance
a *mutual* claim rather than the tutee's word alone: the tutor shows a code
generated at acceptance, the tutee types it in to confirm they met. A tutee who
fabricates attendance needs the tutor's code, not just a `completed` transition.

The consequence is that the code is compared for **presence**, not for
authenticity, so verification fails closed when `sessions.session_pin` is null.
A row that never received a PIN cannot be verified by an empty submission, and
the transition and verification paths both refuse it. The column is
`VARCHAR(2)` with a length check constraint rather than a 4-digit code, because
a peer reads the number aloud across a table and a longer one gets mistyped.

### 8.2 Unit endorsements are not ratings

A rating answers "how was the tutor". An endorsement answers "the tutor knows
this course unit". They are separate rows in `unit_endorsements` rather than
extra columns on `ratings`, because they are consulted by different questions:
standing is computed from `ratings`, and unit coverage is consulted when matching
picks a tutor for a unit. Folding the second into the first would make a claim
about subject knowledge silently move someone's promotion.

An endorsement is scoped to the **session's own** `course_unit_id` and capped at
`MAX_ENDORSEMENTS_PER_RATING`. A corrected submission replaces the rater's
previous endorsements for that session rather than appending to them, so a
mistake is retractable. The unique constraint on
`(session_id, rater_id, course_unit_id)` is what makes that replacement safe
under concurrent retries, and it is a database constraint rather than a service
check because two simultaneous requests would both pass the check.

---

## 9. Security & Compliance

The pilot's threat model is specific: an attacker holding a list of student email
addresses, or a stolen copy of the database. Every choice below is aimed at one of
those two, and the reasoning is recorded so a later change can be judged against
it rather than re-argued from scratch.

> **Status: enforced on the request path.** Everything in 9.1, 9.2, 9.4 and 9.5
> is implemented and unit-tested in `app/core/security.py`,
> `app/core/password_policy.py` and `app/core/config.py`; the limiter in 9.3 lives
> in `app/services/rate_limit.py`. All of it is reached through
> `app/services/auth_service.py`, which every auth route calls.
> `denial_reason`, the password hashers, `create_token_pair` and `decode_token`
> all have production callers, and `app/api/deps.py` guards the authenticated
> routes through the `CurrentUser` and `DatabaseSession` aliases.

### 9.1 Secrets

Three independent secrets, none with a default, all required at startup. The API
refuses to boot without them, because an API that boots with no signing key will
happily issue tokens that nobody can revoke, and one that boots with no pepper can
be checked offline against a stolen database.

| Setting                 | Protects                                     | Rotating it                              |
| ----------------------- | -------------------------------------------- | ---------------------------------------- |
| `JWT_SECRET`            | Signs access tokens                          | Invalidates every issued token unless the old key is in `JWT_PREVIOUS_SECRETS` |
| `JWT_PREVIOUS_SECRETS`  | Verifies tokens signed by retired keys       | Removes the ability to verify old tokens |
| `TOKEN_PEPPER`          | Server-side key for hashing opaque tokens    | Signs every user out; no stored hash matches |

They are separate settings rather than one secret reused, because they protect
different things and rotate for different reasons. Sharing a value would mean one
compromise reaches all three, and rotating one would take the others out.

Placeholder values (`changeme`, `secret`, `replace-me`) and values under 32
characters are rejected. A committed placeholder reaches production more often
than anyone expects, and a warning in a `.env.example` is not a control.

### 9.2 Password storage

Argon2id at the OWASP minimum: 19 456 KiB, 2 passes, 1 lane. The floor is enforced
as a *validation bound in the settings model*, not only by a test, so it cannot be
lowered by an environment variable. Lowering a constant is visible in review;
lowering a config value in a deployment manifest is not.

Raising the parameters is not a migration. Every stored hash encodes the
parameters it was created with, and a successful sign-in transparently rewrites a
hash made under weaker settings, so a raised floor reaches existing accounts
gradually on their own.

Two properties that the auth service must implement matter for an attacker with a
stolen database. Both are available in `app/core/security.py` and neither is
called yet:

- **No PBKDF2 fallback.** A stored `pbkdf2_sha256$` hash is refused outright rather
  than verified. There is no PBKDF2 data in production to preserve, so supporting
  it would only create a weaker path to keep alive.
- **Uniform cost per guess.** An unknown email runs a decoy Argon2 verification
  against a random hash, so "no such user" and "wrong password" cost the same.
  A stored value that is malformed — not a PHC string, or one that names the right
  algorithm but cannot be parsed — is paid for explicitly, because those paths
  fail *before* any Argon2 work happens and would otherwise return measurably
  faster than a wrong password.

### 9.3 Rate limiting

Sign-in, sign-up and the PIN handshake are all bounded. Argon2id makes each guess
expensive, which sets the *cost* of an attempt; these counters set how many
attempts are allowed, which is the half that cost does not provide.

**The counters are rows in `rate_limit_counters`, not entries in a dictionary.**
An in-process counter is per worker process, so with four workers an attacker gets
four times the configured budget for free, and a restart wipes the history —
weakest exactly when the service is busiest and most worth attacking. The PIN
throttle on the session row is the same decision at a smaller scale.

**One row per (scope, key), and the increment is a single statement.**
`INSERT ... ON CONFLICT (scope, key) DO UPDATE SET attempts = attempts + 1
RETURNING attempts, locked_until`. Written the obvious way — read the row, add
one in Python, write it back — the counter loses updates under concurrency: twenty
simultaneous failures all read zero and all write one, so the ceiling is never
reached and batching defeats the limit entirely. The `+ 1` on the right of `SET`
refers to the *stored* value, which is what makes each attempt one atomic step.
This is asserted against twenty real concurrent requests in
`tests/test_rate_limit.py`, and that test fails if the statement is rewritten as
a read-modify-write.

The lock is armed by the same statement that increments, so it cannot be skipped
by arriving all at once.

**Two scopes for sign-in, because each bounds a different attack.**

| Scope | Key | Bounds |
| ----- | --- | ------ |
| `auth.login.account` | Normalised email | Guessing one known account. |
| `auth.login.ip` | Client address | Spraying one address across many accounts. |

Neither alone is sufficient. A per-account limit does nothing against spraying,
because every target account starts at zero failures; a per-address limit alone
lets an attacker spread their guesses across addresses and keep going. Sign-up
has only the address scope, since before an account exists there is no account to
key on.

**The registration scope charges every attempt that reaches the password hash,
not only the successful ones.** Both outcomes have already paid for an Argon2
operation by the time the answer goes out, so both draw on the same budget.
Charging only successes leaves an unbounded hashing budget for anyone willing to
send addresses that already exist — and that request returns 409, which both
identifies real student accounts and buys unlimited CPU while never being
counted. It is a strictly better enumeration oracle than sign-in, where a wrong
password costs the same hash and *is* counted. Rejections that happen before the
hash, such as a deny-listed password, are not charged: they cost nothing.

**A success clears the account counter and not the address counter.** That
asymmetry is deliberate. Forgetting a student's five typos is basic manners. But
refilling the address budget on every successful sign-in would hand anyone
holding one valid account an unlimited number of guesses — sign in, get twenty
more, repeat.

**Both locks are checked before any Argon2 work.** A throttled caller should not
be able to spend server CPU by continuing to try.

**The client address is `request.client` unless a proxy is declared.**
`X-Forwarded-For` is ignored entirely when `trusted_proxy_hops` is 0, because a
header the caller sets is a rate-limit identity the caller chooses, which would
make the ceiling decorative. When proxies *are* declared, the entry counted is the
one that many hops **from the right**: the leftmost entry is written by nobody the
deployment controls, so an attacker prepends a forged address there and has it
believed. Too few hops and every request shares the proxy's address, so one
student's five wrong passwords lock out a campus; too many and forged entries are
trusted. Count them exactly, and fall back to the socket address when the chain is
shorter than declared, rather than guessing which entry to believe.

**Known costs of this design, stated rather than discovered later.**

- A *locked account* returns 429 while an unknown address returns 401, which is a
  weak enumeration signal — it only appears after the attacker has already spent
  five wrong guesses on that address, so it confirms a guess rather than
  answering an unasked question. Closing it entirely would require locking on
  something an attacker cannot vary per guess, which is not available here.
- Conversely, once an *address* is throttled, every account looks identical from
  it: unknown and known addresses get the same 429 body. Were it otherwise the
  address ceiling would become an enumeration oracle and hand out which student
  addresses have accounts — undoing the decoy burn in 9.2.
- Account lockout is a denial of service against any address the attacker knows.
  That is the accepted trade for making offline guessing of a *known* account
  pointless, and the cooldown bounds it. Address lockout has the mirror risk on a
  shared NAT, which is why that counter is per address and never global.
- `429` rather than `403` throughout, so a client can tell "wrong account" from
  "right account, too soon" and wait instead of logging the student out. The wait
  is published in both the `Retry-After` header and `errors.retry_after_seconds`.

All seven thresholds live in `app/core/config.py` and are tunable per
deployment without a code change. The service-level reasoning, including why the
per-IP scope is not reset on success, is in `app/services/rate_limit.py`.

### 9.4 Password acceptance

Length-based, **8 to 128** code points, with no composition rules. Character-class
requirements are well documented to produce `Passw0rd!` — a predictable
substitution that satisfies the rule and is weaker than a passphrase of the same
length. The 128 ceiling exists so that a future move to bcrypt, which truncates at
72 bytes silently, cannot quietly reduce a long password to its first 72
characters.

**The floor was twelve and is now eight.** The reasoning matters, because a long
floor looks like the safer choice and is not. Past about eight characters students
stop inventing and start satisfying — they write `Password1!` and forget it, or
abandon the form. A longer floor therefore rejects honest students without
rejecting attackers, because every guess worth making is short: nobody
brute-forces a twelve character space when the useful guesses are eight characters
and known. The deny-list, not the floor, is what rejects attacker guesses, and
Argon2id's 19 MiB cost is what makes each one expensive.

**Rate limiting on sign-in and sign-up is now in place** (see 9.3), which closes
the gap this paragraph used to name. The eight-character floor is now backed by a
bound on the number of guesses as well as the deny-list, so a leaked student
address is no longer enough on its own. Note the deliberate consequence: the
limiter was added rather than the floor being raised back, because it addresses
the actual threat without the cost to the student.

A small static deny-list covers the passwords that would otherwise make the
Argon2 cost affordable. It is checked at **registration and password change only,
never at sign-in**: a student who chose a password that later lands on a breach
list must still be able to get into their own account, or anyone could lock them
out by reporting their password as common. That is the only place a deny-list is
safe.

The list is static and small on purpose, and is enforced by
`app/core/password_policy.py`, which the registration endpoint must call. A live
breach-API lookup would hand a third party a list of student addresses to check and
would make account creation depend on someone else's uptime. Keeping it short
enough to audit by eye is what makes it a control rather than decoration; it needs a
manual refresh, and that is a known cost rather than an oversight.

The cost of a static list is that it only covers what someone thought to add, and
at a floor of eight a student can reach a keyboard run the list never anticipated.
Entries are therefore listed in **base form**, because `denial_reason` strips
trailing digits and punctuation before the lookup: listing `asshole` refuses
`asshole1` and `asshole!` without naming either, and listing `1q2w3e4r` already
covers the trailing digits of its own longer variants. The list still has holes —
`tests/core/test_password_policy.py` pins the ones found so far, and a new one is
found by trying one, not by a control failing. That is the argument for rate
limiting.

### 9.5 Tokens

- **Access** — JWT, HS256. Carries `sub` (the `public_id`), `type`, `iat`, `exp`
  and `jti`. Nothing else. Roles are **not** in the token; they are read per
  request, so a role change takes effect immediately instead of at the next
  token refresh.
- **Refresh and email verification** — opaque random strings. Only a
  peppered HMAC-SHA256 of the token is stored, so a stolen database yields no
  usable token and no offline attack is possible, because the server-side pepper
  is not in the database.
- **No clock-skew leeway** is configured. A phone whose clock is a few seconds
  behind is signed out rather than tolerated. With a 15 minute lifetime the
  stricter failure is the one worth having, and a leeway setting is deliberately
  absent until a real device demonstrates a need for it.

Symmetric signing is deliberate. Asymmetric signing buys key separation between
issuer and verifier, which matters when a third party must check a token the
issuer cannot mint. That is not this service: it mints and verifies its own
tokens, so rotation is handled by a key set rather than a new key pair. The
saving is that `cryptography` — a compiled wheel of several megabytes — is not
shipped for a capability not in use.

`public_id` rather than the primary key is the `sub` because a UUIDv7 encodes its
creation time, and a leaked primary key would otherwise date and help enumerate
every other record.

Refresh tokens **rotate on every use**. Each exchange issues a new token and
records `replaced_by_id` on the one presented, so the table holds a chain.
Presenting a token that has already been replaced is treated as theft and
revokes the whole family, which signs out the attacker's device and the
legitimate one together. The cost is real: a client that retries a refresh
without storing the new token revokes its own session. That is the correct
trade, because the alternative — tolerating reuse — makes a stolen 30-day token
indefinitely renewable.

The consequence for the client is that **`/v1/auth/refresh` must replace the
stored refresh token with the one in its response.** The token just sent stops
working the moment the response returns.

#### Cold start

The access token lives in memory only, so a cold start has no access token and
must hold the splash screen until it has one. The order matters and is fixed:

1. Read the refresh token from secure storage. Nothing there → the session is
   simply unauthenticated, and this is not an error.
2. Exchange it for a pair, replacing the stored refresh token.
3. `GET /v1/auth/me` for the profile.

A network failure at step 2 or 3 keeps the user on the splash screen **with a
retry**; it does not report them as signed out, because "we could not reach the
network" and "your session ended" are different facts and only one of them is
true. A refresh that is *refused* does clear the token and routes to sign-in.

### 9.6 Logging

- `database_echo` logs SQL **with its bound parameters**, which for this schema
  means email addresses and password hashes. It is refused at startup unless
  `environment` is `development`.
- The frontend transport interceptor logs method, path, status and timing only.
  Headers and bodies are suppressed: headers carry the bearer token, and every
  body in this API is either a credential or a student's academic record.
- Unhandled server errors log the path and a fixed client-facing message.
  Interpolating an unexpected exception's message is how connection strings and
  row contents end up in a student's error toast.
- Every record that leaves the process is redacted of credential-shaped values
  before it reaches a handler, including the rendered traceback, because a
  database error carries the parameters of the statement that failed. See §9.9.

### 9.7 Data protection

- Compliant with the Uganda Data Protection and Privacy Act, 2019 (DPPA). Grades
  and transcripts require explicit consent and secure storage.
- Access tokens are held in memory only and are never written to
  `shared_preferences`. The refresh token is the only secret persisted, and only
  in platform secure storage.
- The client never sees a row's primary key.
- **Transcript storage**: Uploaded verification proofs (Tier 1) are stored securely on the local filesystem of the backend. Only authorized admins and the system can access the raw paths stored in the database.

### 9.8 Schema changes

Alembic, with a naming convention applied to every constraint. Names matter here
because a constraint whose name is generated afresh looks like a drop plus an add
to Alembic, and dropping a unique index takes the guarantee away for the duration
of the rebuild.

`backend/alembic/versions/` is autogenerate output, so the formatter is kept away
from it — reformatting generated files produces churn that hides the real changes
on the next autogenerate run.

### 9.9 Redaction at the logging boundary

SQLAlchemy puts the bound parameters of a failed statement into the text of the
exception it raises. That text is normally swallowed — `register()` catches the
`IntegrityError` from a duplicate address and answers `409` — but that guard is
specific to one exception type. A `DataError` from a mis-sized column, an
`OperationalError` from a deadlock, anything else that escapes the flush reaches
the catch-all handler, which logs the traceback. The traceback carries the INSERT
that creates an account, so it carries the student's Argon2 hash and email
address in cleartext. This was reproduced against PostgreSQL before the control
existed, not assumed.

So redaction happens where log records are formatted, not at each throw site.
`backend/app/core/logging.py` installs a filter on the root logger and its
handlers, which removes credential-shaped values from the message, the arguments
and the rendered traceback: named parameters such as `password_hash`, bare
password hashes in any encoding this service or its history uses (Argon2,
PBKDF2, bcrypt, scrypt), JWTs, and the password in a database URL.

Two deliberate choices:

- **A filter, not a formatter.** A formatter attached at import time is discarded
  when uvicorn installs its own logging configuration at startup, which it always
  does. A filter on the logger survives that.
- **The stack survives.** The filter pre-computes `exc_text` redacted, so the real
  formatter appends that instead of re-rendering the original. An operator keeps
  the frames, the failing statement and the constraint name — the hash goes.

It is a pattern matcher, not a parser. Anything clever enough to know whether a
given key is secret in a given statement is also wrong the first time a statement
is built by a library rather than by us. Over-redacting costs a debugging
session; under-redacting costs the credential.

This is a floor, not a substitute for the controls it complements. Statements are
still logged with their parameters when `database_echo` is set, which is refused
outside `development` for exactly this reason (§9.6), and the SQLAlchemy log
namespace is not covered when a deployment attaches its own handler before the
application starts.

### 9.10 Not yet in place

Stated explicitly so nothing here is mistaken for a control that exists:

- **HTTPS is not yet enforced** by the application, and HSTS is not set. It is a
  deployment responsibility today.
- **No certificate pinning.** Deferred: it breaks certificate rotation in ways
  that lock a pilot out of its own API.
- **CORS defaults to empty**, which is correct for a mobile client and means
  browser origins are untrusted until deliberately configured.
- **No structured audit log** of access to academic records. Required before any
  institutional pilot.
- **Log records carry no request id.** An operator correlating one student's
  report across a proxy log, the application log and a database log has nothing
  to join on. Needs a correlation id propagated from the edge, plus structured
  output, before an institutional pilot.

---

## 10. Non-Functional Requirements

| Requirement            | Target / Approach                                                                              |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| **Latency**            | Matching responses under 1–2 seconds under normal load                                         |
| **Availability**       | Stateless API allows horizontal scaling                                                        |
| **Bandwidth**          | Minimal payloads; images and heavy assets avoided where possible                               |
| **Offline resilience** | Client can queue non-critical actions; critical flows remain online-first                      |
| **Observability**      | Structured logging + future metrics (request latency, match success rate, rating distribution) |

---

## 11. Future Extension Points

- Institutional SSO and direct academic database integration
- LMS plugin / LTI support
- Advanced matching (topic embeddings, availability calendars)
- Analytics dashboard for university administrators
- Multi-university support with tenant isolation

---

## 12. Related Documents

- [Contribution Guide](./Contribution.md) — Contribution guidelines and Code of Conduct
- [Project Structure](./project-structure.md) — Repository layout and dependency direction
- [README.md](../README.md) — Project overview and local setup
- [MVP Brief](./MVP_Brief.md) - MVP Brief, covers what is in scope for the MVP and what is not and also future improvements.
- Pilot roadmap and research proposal (project root / docs)

---

**Maintainers**: Gilbert Asiimwe ([@asiimwe-dev](https://github.com/asiimwe-dev))
