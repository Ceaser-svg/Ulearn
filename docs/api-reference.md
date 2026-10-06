# API Reference

The public HTTP contract. Every route lives under `/v1`, mounted in one place
(`backend/app/api/router.py`) so the prefix cannot drift between modules.

Base URL in development: `http://127.0.0.1:8000`.
Interactive schema: `/docs`.

## Conventions

**Identifiers.** Every identifier a client handles is a public UUID. No endpoint
returns a primary key, and a request taking an id takes that resource's *public*
id. A `public_id` is not a primary key and cannot be assumed sequential.

**Authentication.** Endpoints marked *auth* require
`Authorization: Bearer <access_token>`. The bearer token is checked for its type
as well as its signature, so a refresh token presented where an access token is
expected is a 401 rather than a 30-day session.

**No role claims in tokens.** Roles are read from the database on every request.
A suspended account's next request reflects that immediately instead of whenever
its access token happens to expire.

**Timestamps** are ISO 8601 with an offset, in UTC.

## Service probes

`GET /health` is a liveness probe and does not access the database. `GET
/ready` is a readiness probe and returns `200 {"status":"ok","database":"ok"}`
only when the API can execute a database health query. A database failure
returns `503` with the standard problem response; the failure detail does not
include connection or credential information. Managed-cloud traffic should use
`/ready` for routing and `/health` for process liveness.

## Admin

The `/v1/admin/*` routes are reserved for accounts provisioned with the
explicit `admin` role. There is no public admin registration endpoint. The
separate MUST web application uses these routes with the same bearer-token
contract as the mobile app.

`GET /v1/admin/users` returns a bounded, paginated operational view containing
public id, email, display name, roles, academic location, active state, and
creation time. It never returns password hashes, refresh tokens, consent
timestamps, competency evidence, or internal database ids.

`GET /v1/admin/audit-events` returns the append-only audit events created by
privileged actions. Each event carries the actor's `actor_id`, `actor_email`, and
`actor_name`, so an auditor can answer "who did this" from the log alone rather
than by joining against the users list; `actor_name` falls back to `actor_email`
for a staff account registered without a full name. Audit context contains only
action-specific identifiers and pagination metadata; request bodies, credentials,
and evidence are not stored.

`GET /v1/admin/competencies` returns paginated competency claims for operational
review. Each row carries the decision context rather than leaving it to be looked
up: `grade_label`, `grade_points`, `competency_min_points` (the bar for that
university's scale), the server's own `meets_threshold` verdict, `status`,
`rejection_reason` when the last review refused it, `created_at`, and `verified_at`
when it has been verified. `meets_threshold` is `false` for a `pending` or
`rejected` claim and `true` only once verified, and it is `false` when the
university has no grading scale loaded, because nothing can be verified on a scale
that does not exist. The bar is omitted for such a university rather than sent as
a value to compare against. A verified competency carries no `rejection_reason`;
a claim holds one status or the other.

| Query     | Type   | Notes                                                                                            |
| --------- | ------ | ------------------------------------------------------------------------------------------------ |
| `status`  | string | Optional. `pending`, `rejected`, or `verified`. Omitted means every status. Anything else is a 422. |

Filtering is applied by the API rather than by the client, so `total` and every
page describe the filter that was asked for.

`PATCH /v1/admin/competencies/{competency_id}/review` accepts
`{"status": "verified"}` or `{"status": "rejected", "rejection_reason": "..."}`.
Only `pending` claims can be reviewed; rejection reasons must be nonblank.
Successful decisions record the reviewer in the competency and append an audit
event. Verification grants the tutor role and creates the provisional tutor
profile through the backend service.

`GET /v1/admin/tutor-standings` returns paginated, privacy-safe tutor standing
aggregates for operations. These endpoints require the explicit `admin` role,
use public identifiers only, and never return uploaded evidence documents,
password hashes, refresh tokens, consent timestamps, or internal database ids.
All list responses use the standard `items`, `total`, `offset`, and `limit`
pagination shape.

## Errors

Every error the API returns — framework validation, domain rejection, or an
unhandled fault — has the same body, [RFC 9457 problem details][rfc9457],
served as `application/problem+json`. The client has one shape to parse.

```json
{
  "type": "https://peerpass.app/problems/authentication_required",
  "title": "Authentication required",
  "status": 401,
  "detail": "That email or password is not right.",
  "instance": "/v1/auth/login",
  "code": "authentication_required"
}
```

| Field      | Notes                                                              |
| ---------- | ------------------------------------------------------------------ |
| `detail`   | Human-readable and **safe to show a student**. Never a stack trace, SQL fragment, or token. |
| `code`     | Stable machine-readable slug. Absent on the rare 4xx built directly from an `HTTPException`. |
| `errors`   | Field name → reason, **or** a single `retry_after_seconds` integer on a 429. |

The envelope is rendered once, in `backend/app/main.py`. A route raises; it never
builds an error body by hand.

### `Retry-After`

Every 429 carries the wait in two places, on purpose:

- The **`Retry-After` header**, in seconds. This is what RFC 6585 asks for and
  what reverse proxies, load balancers and SDKs read.
- **`errors.retry_after_seconds`** in the body, as a JSON integer, not a string.
  This project's own clients read that.

Send one without the other and either the spec or the app is wrong, and both kinds
of consumer exist.

### `X-Request-ID`

Every response carries one. Send your own and it is echoed back when it is a
plain token (letters, digits, `.`, `_`, `~`, `-`, up to 200 characters); anything
else is replaced with a generated id, because the value reaches log text and a
newline in it would be an injection primitive. The same value is attached to
every log record for the request, including a 500, so quoting it in a bug report
lets an operator find the exact request. Treat it as opaque.

### Status codes

| Status | `code`                  | When                                                        |
| ------ | ----------------------- | ----------------------------------------------------------- |
| 400    | `error`                 | Bad request, from an `HTTPException`.                        |
| 401    | `authentication_required` | Missing, expired, or wrong-type token; refused credentials. |
| 403    | `not_permitted`         | Authenticated but not allowed. Wording never names the internal reason. |
| 404    | `not_found`             | Absent, or not visible to this caller.                       |
| 409    | `conflict`              | Collided with existing state. Expected on a retried mobile request. |
| 422    | `validation_failed`     | One or more submitted values were rejected. Carries `errors`. |
| 429    | `too_many_requests`     | Too many attempts. Wait the interval in `Retry-After`.        |
| 500    | `internal_error`        | Unhandled fault. The cause is logged server-side; the body says nothing about it. |

## Auth

### `POST /v1/auth/register`

Create an account. **201.** No auth.

An account is an email and a password and nothing else. The name, faculty, and
year are collected by the onboarding wizard that runs immediately afterwards,
which is a separate screen a student can leave and come back to.

```json
{
  "email": "student@must.ac.ug",
  "password": "a-long-enough-password"
}
```

Responses `201` with tokens and the new account in one body, so the client never
holds a valid token it cannot yet render a name for.

**Errors**

| Status | `detail`                                             |
| ------ | ---------------------------------------------------- |
| 409    | `An account already exists for that email address.`  |
| 422    | `That password cannot be accepted.` — the reason is in `errors.password` |
| 429    | `Too many accounts created from this network. Try again later.` |

The password is 8–128 characters, must not be entirely whitespace, and is
checked against a common-password deny-list. The reason is returned as
`errors.password`, e.g. `Password must be at least 8 characters long.`,
`That password is too common. Choose something longer that is not a dictionary
word or a keyboard pattern.`

Lowering the minimum to 8 cannot invalidate an existing password: this endpoint
creates accounts, and `POST /v1/auth/login` enforces no minimum at all (only the
128 maximum), so a password accepted under the old 12-character rule keeps
working.

A new account has `full_name: null` and holds only the `student` role. The tutor
role is not grantable at registration; it is earned by declaring a grade and
having that competency verified.

### `POST /v1/auth/login`

Exchange credentials for a token pair. No auth.

```json
{
  "email": "student@must.ac.ug",
  "password": "a-long-enough-password"
}
```

**Errors**

| Status | `detail`                                       |
| ------ | ---------------------------------------------- |
| 401    | `That email or password is not right.`         |
| 422    | Field-level, from the request schema.          |
| 429    | `Too many sign-in attempts. Wait before trying again.` |

An unknown address and a wrong password produce the **same** 401, the same body,
and the same work. A decoy Argon2 verification runs when the account is not
found, so response time does not distinguish the two cases. This is deliberate:
the pilot's realistic attacker holds a list of student addresses, and telling
them which of them have an account hands over half the target.

### Sign-in rate limits

Two counters, both checked before any Argon2 work. Each is per key, so one
student's lockout never affects anyone else:

| Counter | Keyed on | Default ceiling | Cooldown |
| ------- | -------- | --------------- | -------- |
| Account | The normalised email address | 5 failures | 15 min |
| Client address | The caller's IP | 20 failures | 15 min |

The fifth wrong password still returns 401 — the student is entitled to the tries
they were given — and the sixth returns 429. A successful sign-in **clears the
account counter but not the address counter**: clearing the address budget would
let anyone holding one valid account launder an unlimited number of guesses by
signing in between runs.

The address ceiling is the one that bounds a spraying attack, where every target
account starts at zero failures. Without it, a per-account limit alone does not
slow that attack down at all.

A 429 is returned for a locked account whether the password is right or wrong.

Once an address is throttled, **every** account looks the same from it: unknown
and known addresses both get the identical 429 body. Were a throttled request to
answer 401 for an unknown address and 429 for a locked one, the ceiling would
hand out the list of which addresses hold accounts — undoing the decoy burn
above.

Sign-up is throttled per address too, at 50 accepted registrations per hour by
default. Each registration that reaches the password hash costs a full Argon2
operation, so that budget bounds CPU rather than merely counting requests.

**Both outcomes are charged.** A registration that succeeds *and* one refused as
a duplicate both draw on the same budget, because both have already paid for the
hash by the time the answer is sent. Charging only the successes — which is what
this did at first — leaves the endpoint with an unbounded hashing budget for
anyone sending addresses that already exist, and such a request returns 409, which
identifies real student accounts *and* buys unlimited CPU while never being
counted. The duplicate is still answered with
`An account already exists for that email address.` until the budget is spent;
throttling never replaces that message with an error the student cannot act on.

A rejection that happens *before* the hash is not charged, because it costs
nothing: a password on the deny-list, a password too short or too long for the
schema, or a caller already throttled. So a student who fumbles the policy a few
times is not charged for it.

All seven settings are configurable, and the defaults are in
`backend/app/core/config.py`. See `docs/architecture.md` for how the client
address is established and why the counters live in the database.

### `POST /v1/auth/refresh`

Exchange a refresh token for a new pair. No auth — the token is the credential.

```json
{ "refresh_token": "..." }
```

**The client must replace its stored refresh token with the one in this
response.** The token just sent stops working the moment this returns; sending
it a second time is treated as theft and revokes the entire chain.

Refresh tokens live 30 days and rotate on every use. Presenting an already-used
token revokes the family, so a stolen token is usable at most once and its use
signs out the legitimate device too.

### `POST /v1/auth/logout`

Revoke the caller's refresh token. *Auth.* **204**, no body.

The body is optional:

```json
{ "refresh_token": "..." }
```

**204 whether or not a token was presented.** Sign-out is what the student asked
for, and refusing because the server had not heard of the token would leave
someone unable to end a session on a device that lost its state. A client that has
already cleared its token store can still sign out cleanly.

### `GET /v1/auth/me`

The caller's own record. *Auth.*

The **only** endpoint that returns `academic_data_consented_at`. `UserResponse`
deliberately has no consent field, so no other route can leak it by accident.

## Users

### `PATCH /v1/users/me`

Apply an onboarding step. *Auth.* Returns the updated record in the same shape
as `GET /v1/auth/me`, consent timestamp included, because the client needs the
stored `academic_data_consented_at` to know its own grant was recorded.

Every field is optional and an absent one is left alone, because the wizard saves
each step as it is completed. A step sending only `full_name` must not blank the
faculty picked a moment earlier, and a retried step must be safe to send twice.
This is why it is `PATCH` and not `PUT`: a `PUT` would have to require the whole
profile, so a step not yet reached would be sent as `null` and erase what an
earlier step had just saved.

| Field                    | Type          | Notes                                                |
| ------------------------ | ------------- | ---------------------------------------------------- |
| `full_name`              | string \| null | 2–160 characters after trimming.                     |
| `university_id`          | UUID \| null  | Public id.                                          |
| `faculty_id`             | UUID \| null  | Public id of a `subject`. See [Faculties are subjects](#faculties-are-subjects). |
| `year_of_study`          | int \| null   | 1–6.                                                |
| `academic_data_consented` | bool \| null | `true` records consent. **Never withdraws it.**      |
| `primary_course_unit_ids` | UUID[] | Each a course unit **inside the caller's own faculty**. `[]` clears them. |

A field is cleared by sending an explicit `null`, which is what makes the partial
update unambiguous.

**Changing faculty clears the declared course units.** Sending a `faculty_id`
different from the one stored drops `primary_course_unit_ids` in the same request,
because those units belong to the old faculty's catalogue and no other endpoint
would accept them afterwards. A student left holding modules the API refuses to
act on has a profile that looks complete and silently is not.

**Primary course units are validated against the faculty being set in the same
request**, not the faculty stored before it. The wizard's second and third steps
can save together, and validating against the old faculty would reject a correct
choice.

| Status | `detail`                        | `errors`                          |
| ------ | ------------------------------- | --------------------------------- |
| 404    | `One or more course units could not be found.` | Keyed by position. |
| 422    | `That course unit belongs to a different faculty.` | Keyed by `primary_course_unit_ids`. |
| 422    | `That course unit does not belong to your university.` | Keyed by `primary_course_unit_ids`. |

A course unit from another faculty is a validation error rather than a 404 on
purpose: the unit exists, the student simply may not hold it, and saying "could not
be found" would send them looking for a typo in an id the app never showed them.

`academic_data_consented: true` stamps `academic_data_consented_at` **once** and
never moves it. Consent cannot be withdrawn through this field: the Uganda Data
Protection and Privacy Act requires a withdrawal to be as express as the original
grant, and to be logged.

**Errors**

| Status | `detail`                        | `errors`                          |
| ------ | ------------------------------- | --------------------------------- |
| 404    | `That university could not be found.` |                                |
| 404    | `That faculty could not be found.`    |                                |
| 422    | `Some of the details you entered are not valid.` | Keyed by field name. |

### `DELETE /v1/users/me`

Close the caller's account. *Auth.* **204, no body.**

Anonymises rather than deletes. Academic evidence is the part of the record that
cannot be recreated and that other people rely on — a session a tutor taught, a
rating a student left, an endorsement about a course unit — so it is kept, while
everything that identifies the account is scrubbed: name, email, phone,
password hash, university and faculty, and every role. The row stays, marked
`is_deleted`, so the evidence still refers to somebody.

The access this leaves behind is worth being precise about. **All authentication
is refused for the account**, including a refresh token issued before the
deletion, so a deleted user cannot continue to hold a session through a credential
the deletion did not revoke.

Every refresh token for the account is revoked in the same transaction, so a
token that has not been used yet cannot be used later.

## Academics

Read-only, administrator-loaded reference data. No create, update, or delete: a
student who could invent a course unit their own transcript never mentioned could
manufacture a match for it.

**All three are unauthenticated.** The sign-up form shows a student where they
study before they have an account, and a published faculty list leaks nothing a
prospectus does not.

### `GET /v1/academics/universities`

Every institution, alphabetically. `grading_scale_id` is nullable: a tutor cannot
be matched until their university has a scale, and the matching service reports
that rather than assuming one.

```json
[
  {
    "id": "8e2c…",
    "name": "Makerere University",
    "grading_scale_id": "1f4a…"
  }
]
```

### `GET /v1/academics/faculties?university_id=<uuid>`

Every faculty belonging to the selected university, alphabetically. Returns
`[{ "id": …, "name": …, "description": …, "university_id": … }]`.

#### Faculties are university-scoped subjects

`GET /faculties` returns rows from `subjects`, and `PATCH /users/me` stores
`faculty_id` as a `subjects` public id. A faculty belongs to one university, so
the selected university is required for the lookup and a profile cannot combine
IDs from different universities.

### `GET /v1/academics/programs?university_id=<uuid>`

Every degree or postgraduate offering seeded for the selected university,
ordered by faculty and name. Programs are reference information and are
separate from course units, which remain the records used by matching.

### `GET /v1/academics/course-units`

**Requires authentication.** Returns only the course units inside the caller's own
university **and** their own faculty. Ordered by university, then by code — a
student scanning for `BIT 221` is looking for a code, not for alphabetical
position.

| Query        | Type | Notes                                                     |
| ------------ | ---- | --------------------------------------------------------- |
| `subject_id` | UUID | Optional. A faculty **public** id.                       |

The faculty scope is the server's, not the client's. `subject_id` can only ever
narrow a list that is already inside the caller's own faculty, so a client cannot
use it to read another faculty's catalogue — asking for one returns `[]`, not that
faculty's units. An account with no faculty chosen is answered with `[]` too:
there is nothing to scope to, and an empty list is the honest answer rather than an
error the student did nothing to cause.

| Status | When                                                            |
| ------ | --------------------------------------------------------------- |
| 401    | No token. Onboarding uses this *after* sign-up, so it is always authenticated. |

A malformed `subject_id` is a 422 from FastAPI, not a silently empty list. An
unrecognised but well-formed one returns `[]`: the client filtered on a value it
believed exists, and the honest answer to "units in this faculty" is "none". A
404 would put the wizard into an error state for something the student did not do.

Universities and faculties stay public (see below) because the wizard has to offer
a choice *before* an account has one of each.

This is the endpoint onboarding's **third** step uses, to record the units a
student takes. It is not matching: a declared unit is a preference, and nothing
is matched against it until the matching slice lands. Every seeded faculty
publishes at least one unit, so this list is empty only for a university whose
catalogue has not been loaded — which the app must still let such a student
leave onboarding past — see
[A faculty with no course units](#a-faculty-with-no-course-units).

### A faculty with no course units

A student whose faculty publishes nothing can never declare a primary course
unit. Every endpoint that depends on declared units must therefore tolerate their
absence rather than treating it as an incomplete account:

- `PATCH /v1/users/me` accepts `primary_course_unit_ids: []`. An empty list is a
  request to clear the selection, not a validation error.
- No endpoint reads a declared unit as a precondition of anything. They are a
  matching input, and matching already answers honestly for a student who has
  none.
- The client must not treat "no declared units" as "onboarding not finished",
  or the router would return such a student to the wizard on every launch, for
  ever, with nothing they could do about it.

### `GET /v1/academics/grades`

The grade catalogue for the caller's university, each entry carrying the points
value on that university's scale.

`grade_id` is what a tutor posts, never a raw number. A client that could send
`grade_points` directly would let a tutor claim an A on a scale their university
does not use, and the threshold check would then compare two incompatible
numbers.

#### Decimals are JSON strings, not numbers

Every `Decimal` on the wire is a **string** — `"grade_points": "5.00"`,
`"max_points": "5.00"`, `"competency_grade_points": "4.00"`, `"score": "4.50"` —
never a JSON number.

A JSON number becomes a double in every mainstream client, and a double cannot
represent every `numeric(6,2)` value, so a number here would be silently rounded
on its way to a display that only ever shows two places. The string keeps the
exact value the university recorded.

This is a **contract, not an incidental encoding**. It broke tutor registration
once already: the Flutter client cast `grade_points` to `num`, the cast raised a
`TypeError`, and the grades list never loaded, so no tutor could be registered.
Clients must read these fields through `readDecimal` in
`frontend/lib/core/models/json_decimal.dart`, which accepts both a string and a
number so a forward-compatible server change cannot become a dead screen.

`tests/test_academic_wire_shape.py` pins the shape on the server side. Read a
decimal that is absent with `readDecimal` (null) or `readRequiredDecimal` (a
`FormatException` the client reports as a server fault) — never with `as num`,
and never by defaulting a missing grade to zero, which would let a tutor
register with a grade that fails the bar.

### `GET /v1/academics/grading-scales`

The scales themselves, including `competency_min_points` — the bar a verified
grade has to clear for a tutor to be proposed for a unit on that scale.

## Competencies

### `POST /v1/competencies`

A tutor claiming competence in a course unit. 201 with the competency, created
`unverified`.

`{"course_unit_id": "1f4a…", "grade_id": "…", "source": "transcript", "evidence_reference": "…"}`.
The claim is a claim until reviewed; nothing here grants standing.

### `GET /v1/competencies/me`

The caller's own competencies.

### `GET /v1/competencies/{competency_id}`

One competency, by public id.

### `PATCH /v1/competencies/{competency_id}/review`

An administrator's decision on a pending claim: `{"status": "verified",
"rejection_reason": "..."}`. 200 with the reviewed competency.

`rejection_reason` is **required** when the status is `rejected`. A tutor whose
claim was turned down with no stated reason has nothing to fix and no way to try
again, and the alternative — a rejection that looks arbitrary — is how a
verification process loses the people it is meant to be checking.

## Tutors

Two read-only, student-facing views of a tutor. Both require a signed-in user, and
**neither creates a `tutor_profiles` row.** The row belongs to a user holding the
tutor role and is created when the role is granted, so a browse that minted one
would hand every signed-in student a `probationary` standing and zero counters
merely by opening the screen.

### `GET /v1/tutors/top`

The discovery rail: tutors in the caller's own **faculty** who clear the
competency bar, most endorsed first.

Two different silos apply, and they are not the same one. Without
`course_unit_id` the rail is filtered by faculty, so it answers "the tutors in my
faculty" — a student of Medicine is not offered Computing tutors to browse. With
`course_unit_id` the rail answers for that one unit, and the competency records
that make it work are per-unit, so the unit's own faculty governs: a tutor is
proposed for a unit only if that tutor holds a competency for **that** unit, and a
competency can only be recorded for a unit the tutor's faculty teaches. Ask for a
unit outside your own faculty and the answer is `[]`, not a 404: the unit exists,
it is simply not yours to rail on.

| Query            | Type | Notes                                                                     |
| ---------------- | ---- | ------------------------------------------------------------------------- |
| `course_unit_id` | UUID | Optional. A course unit **public** id. Narrows the rail to that unit.      |
| `limit`          | int  | Optional. Default `10`, between `1` and `20`. Out of range is a 422.       |

```json
[
  {
    "user_id": "8e2c…",
    "full_name": "Rail Tutor",
    "standing": "verified",
    "average_rating": "4.10",
    "completed_sessions": 9,
    "endorsed_course_unit_ids": ["1f4a…"],
    "endorsement_count": 3
  }
]
```

Order is endorsement count (desc), then average rating (desc, unrated last), then
completed sessions (desc), then the displayed name (asc). The name tiebreak is
what makes the list stable: without it the same screen can reorder itself between
two paints of the same data.

The rail can legitimately come back empty. A student has no competencies to
match before they have submitted any proof, and a university whose catalogue is
not loaded gives them no unit to ask about; and a student who names a unit
outside their own faculty gets `[]` rather than a tutor from a faculty they do not
belong to.

`average_rating` is `null` for a tutor with no ratings — absence of evidence, not
a bad score — and is rounded to two decimal places for display, half-up. Eight
ratings totalling 33 average 4.125 and are sent as `"4.13"`.

`endorsed_course_unit_ids` is capped at 5 units, most endorsed first;
`endorsement_count` is the true total across every unit, so a tutor endorsed in
fourteen units is not summarised by any five of them. The detail screen caps its
list the same way, so a client can lay out both from one assumption.

A tutor is left out when they are `suspended`, belong to another university, hold
no profile to rank on, or have no verified grade at or above the university's
`competency_min_points`. The caller is never on their own rail. Provisional and
reduced tutors **are** listed: only `suspended` is disqualifying.

| Status | `detail`                                                     | `errors`                          |
| ------ | ------------------------------------------------------------ | --------------------------------- |
| 401    | Sign-in required.                                            |                                   |
| 422    | Some of the details you entered are not valid.               | `university_id` — the rail is the caller's own university's, so there is nothing to fall back to. |

A `course_unit_id` that is well-formed but unknown, or that belongs to another
university, returns `[]` rather than a 404 or a 422: the client filtered on a
value it believed existed, and the honest answer to "tutors for this unit" is
none. Same rule as `GET /v1/academics/course-units`.

### `GET /v1/tutors/{user_id}`

One tutor's public profile, for a screen the student opened from the rail.

```json
{
  "profile": {
    "user_id": "8e2c…",
    "full_name": "Detail Tutor",
    "standing": "verified",
    "average_rating": "4.13",
    "completed_sessions": 7
  },
  "endorsed_course_unit_ids": ["1f4a…"],
  "endorsement_count": 2
}
```

`profile` is `TutorProfileSummary`, the same trimmed shape matching sends, so the
suspension reason and the raw rating total cannot reach a student by appearing
here. A `suspended` tutor *is* readable, with the standing visible: a student who
booked them has to be able to find out.

Not scoped to the caller's university and not excluding the caller. The
university boundary is on discovery; every field here is one the rail already
carries, so answering it for a tutor found elsewhere leaks nothing new.

| Status | `detail`                          | `errors` |
| ------ | ---------------------------------- | -------- |
| 401    | Sign-in required.                 |          |
| 404    | That tutor could not be found.    |          |
| 422    | Malformed id.                     |          |

A 404 covers both "no such user" and "that user is not a tutor". They are the
same answer on purpose: a route that distinguished them would confirm which
accounts hold the tutor role.

## Matching

What the platform is willing to propose, and why not the others. A bare list of
names is not something a student can argue with, and a tutor who is passed over
with no reason has no way to learn what to fix.

Both matching routes are `POST`, take the same body, and answer the same shape.
The only difference is whose course unit the question is about, and the service
runs one query for both so the eligibility rules cannot drift apart.

| Route                                                | `request_id` in the answer |
| ---------------------------------------------------- | -------------------------- |
| `POST /v1/matching/suggestions`                       | `null`                     |
| `POST /v1/matching/help-requests/{request_id}/matches` | the request's public id    |

```json
{
  "course_unit_id": "1f4a…",
  "topic": "quick sort",
  "widen_to_subject": false,
  "limit": 20
}
```

`widen_to_subject` is opt-in and reported back as `widened`. Widening by default
would return tutors who cannot help with the course the student asked about,
which is worse than returning none and saying so.

```json
{
  "request_id": null,
  "course_unit_id": "1f4a…",
  "widened": false,
  "candidates": [
    {
      "tutor": { "user_id": "8e2c…", "full_name": "Tutor Example", "standing": "verified", "average_rating": "3.60", "completed_sessions": 6 },
      "course_unit_id": "1f4a…",
      "competency_grade_points": "4.00",
      "meets_threshold": true,
      "score": 6.36
    }
  ],
  "exclusions": [
    { "tutor_id": "9b3d…", "reason": "below_threshold" },
    { "tutor_id": "4c8e…", "reason": "unverified" }
  ],
  "no_eligible_tutors": false,
  "generated_at": "2026-03-04T09:12:00+00:00"
}
```

`request_id` is `null` for the unit-only query because nothing backs it. An id
minted there would name no row, and a client that stored it would follow it to a
404 and conclude the platform lost the request it had just made.

A candidate is a tutor with a **verified** grade at or above
`competency_min_points` for that unit, at the caller's own university, with a
profile, and not `suspended`. Provisional standing is a ranking input rather than
a disqualification — otherwise no tutor could ever earn the Verified standing
that reading requires.

`reason` is a stable code, and the set is generated from one constant
(`MATCH_EXCLUSION_REASONS`) so a documented reason cannot drift from one the
engine emits:

| Code                 | Why the tutor is not proposed                                       |
| -------------------- | ------------------------------------------------------------------- |
| `unverified`         | The grade is a claim nobody has checked yet. Checked before the number, so a tutor with an unverified A is not told their problem was the grade. |
| `same_university_only` | Discovery is bounded to the caller's own institution.             |
| `suspended`          | Revoked for student-facing matching.                                 |
| `below_threshold`    | A verified grade under `competency_min_points`. The bar is inclusive. |
| `not_the_tutor`      | Verified grade and the role, but no profile to rank on.              |

`score` is relative: the client shows order, not a number a student could compare
across requests. Ties are broken by grade, then name, then the course unit's
code, so the order does not depend on the query plan.

`no_eligible_tutors` is sent explicitly rather than left as an empty list, so the
app can say why nothing appeared instead of showing a blank screen.

### `POST /v1/matching/help-requests`

`{"course_unit_id": …, "topic": "…", "description": "…"}`. 201 with the request.

### `GET /v1/matching/help-requests/me`

Every open help request the caller created, newest first.

### `GET /v1/matching/help-requests/{request_id}`

One help request the caller owns. Someone else's is a 404 rather than a 403, so
the response does not confirm that it exists.

## Choosing a tutor, and the tutor answering

A proposed list is not a decision. The student names one tutor for a help
request, that tutor confirms or declines, and only a confirmation creates the
session.

`PENDING_CONFIRMATION` and `DECLINED` are the two states this added. A request
the chosen tutor has not answered is `pending_confirmation`, and it stays that
way indefinitely — there is no expiry job, because an unanswered request that
quietly closed would leave a student who applied and heard nothing.

### `POST /v1/matching/help-requests/{request_id}/select`

`{"candidate_tutor_id": "8e2c…"}`. The student names one tutor. 200 with the
updated help request, now `pending_confirmation` and carrying `matched_tutor`.

The eligibility gate is **re-derived here**, not read off the list the client is
holding. The service re-runs the same candidate search matching answers with and
refuses anyone it would not propose, so a tutor id posted directly still has to
pass the competency, grade, university and standing checks for that unit. That
rule lives in one place; a second copy of it would be a second copy to drift, and
it would drift at exactly the moment a student is deciding who to trust.

Reachability is checked, not rank: a tutor who passes the gate is acceptable
even if a client that asked for a short list would not have been shown them. A
refusal whose only justification is which page the student had scrolled to is
not a useful one.

| Status | `detail`                                                                | `errors` |
| ------ | ---------------------------------------------------------------------- | -------- |
| 401    | Sign-in required.                                                      |          |
| 404    | That help request could not be found.                                  |          |
| 409    | This help request is no longer waiting for a tutor to be chosen.      |          |
| 422    | You cannot choose yourself as your own tutor.                          | `candidate_tutor_id` |
| 422    | That tutor cannot be chosen for this help request.                     | `candidate_tutor_id` |

"Not eligible" and "no such user" are one answer on purpose: distinguishing them
would turn the route into a probe of who holds the tutor role at that university,
which the exclusions in the matching response already answer.

### `POST /v1/matching/help-requests/{request_id}/decline`

No body. The chosen tutor turns the request down. 200 with the help request,
now `declined`.

Scoped to the tutor the student named, so the answer to "not yours" and "not
there" is the same and a student cannot decline their own request from the other
end of the platform.

`declined` is terminal rather than a return to `open`. A request the tutor
refused is not the same as one nobody was ever asked, and the student reads the
two differently; re-opening it would also let a tutor decline and then watch the
student re-select them. The recovery is a new request, which keeps the record of
what was asked intact.

| Status | `detail`                              | `errors` |
| ------ | ------------------------------------- | -------- |
| 401    | Sign-in required.                     |          |
| 404    | That help request could not be found. |          |

### `GET /v1/matching/help-requests/awaiting-me`

Every help request where **this** caller is the chosen tutor and has not yet
answered. The list a tutor's "Waiting on you" screen shows.

Scoped to the caller in the query rather than filtered after the fact, so the
response can never contain a request the caller is not the tutor for.

### `POST /v1/matching/suggestions`

The canonical path for the unit-only query. It used to be registered at
`/matching` as well; two URLs for one handler means two things to keep working,
since which one a client reaches depends on the base URL it was configured with.

### `POST /v1/matching/help-requests/{request_id}/matches`

Answers for the course unit **that request** was created for. A body naming a
different unit is a 422 with `course_unit_id` named, rather than being quietly
ignored: this route used to match whatever unit the body carried, so a client
asking "who can take this request" was answered about another course entirely.

| Status | `detail`                                                      | `errors`                          |
| ------ | -------------------------------------------------------------- | --------------------------------- |
| 401    | Sign-in required.                                              |                                   |
| 404    | That help request could not be found.                          |                                   |
| 422    | Some of the details you entered are not valid.                 | `course_unit_id` — must match your university, and for the request-backed route must be the unit that request was created for. `university_id` — set a university first. |

## Sessions

All routes require a signed-in user and are scoped to the caller's own
sessions; a session the caller is not part of is a 404, not a 403, so the
response does not confirm that someone else's session exists.

### `POST /v1/sessions`

Confirms a selected help request and creates the live session. 201 with the
session, and a two-digit handshake PIN is issued.

The PIN is **not** in the response. It belongs to the tutor and is read from
`GET /v1/sessions/{session_id}/pin`; see below for why it is not shared.

```json
{
  "help_request_id": "3bf3…",
  "course_unit_id": "1f4a…",
  "topic": "quick sort",
  "duration_minutes": 45
}
```

This is a **confirmation, not a claim**, and it used to be the other. Any tutor
could create a session against any unselected request, which set
`matched_tutor_id` to the caller and left the student never asked — the inverse
of the decision the platform exists to make. Now only the tutor the student
already named may confirm, and only from `pending_confirmation`.

One confirmation per request. The `session_per_request` unique constraint is the
real guarantee, since two simultaneous requests would both pass a check made of a
read; the status check is what turns the loser of that race into a 409 rather than
a 500.

| Status | `detail`                                                       | `errors` |
| ------ | -------------------------------------------------------------- | -------- |
| 401    | Sign-in required.                                              |          |
| 403    | Only the tutor the student chose can confirm this request.     |          |
| 403    | The student cannot create the accepted session.                |          |
| 404    | That help request could not be found.                          |          |
| 409    | This help request is not waiting for this tutor's confirmation. |          |
| 422    | Some of the details you entered are not valid.                 | `course_unit_id` — must match the request. `duration_minutes` — at least 1. |

### `GET /v1/sessions/me`

Every session the caller is part of, newest first. The route is `/me` rather
than `""` so it cannot collide with `GET /v1/sessions/{session_id}`.

### `GET /v1/sessions/{session_id}`

One session, by public id.

### `POST /v1/sessions/{session_id}/transition`

`{"status": "..."}` to advance or cancel. The legal moves are enforced in the
service, not here: requested → accepted → completed, and cancellation from
anything that has not completed. An illegal move is a 409.

`completed` has an **empty** allowed set, so a session can only be completed
once. That is what makes the accrual below happen exactly once rather than once
per retry: the session's minutes and the tutor's `completed_sessions` are written
after the status is assigned, and a second `completed` transition is refused
before either write is reached.

The minute accrual runs on this transition, not on the status column. Nothing
else can reach it, and the ordering matters: a transition that handed the row to
the accrual before recording `completed` banked nothing at all, silently, on
every call.

### `POST /v1/sessions/{session_id}/verify-pin`

`{"pin": "42"}` — **the tutee submits the code the tutor read out.** Moves the
session to `in_progress` when the code matches.

The tutee only. A tutor asking here gets a 403: they are the one reading the
digits aloud, so entering them would prove nothing, and it would let a tutor
start a session on behalf of a student who never arrived.

Two-digit, so the whole search space is 100 values, which is why attempts are
counted. After **5** wrong entries the tutee is put on a **15 minute** cooldown
and every further attempt — including the correct one — is a **429** carrying
`retry_after_seconds`. The counter is on the session row, not in process memory,
so it survives a restart and is shared across workers; it is committed on the
failure path, and reset by a success. A **missing stored PIN is refused**, never
treated as a match.

### `GET /v1/sessions/{session_id}/pin`

The tutor's half of the handshake: the two digits to read out. **403 for the
tutee**, because a tutee who could read their own code would have nothing to
prove. Unavailable once the session has started.

```json
{
  "session_id": "9f35…",
  "session_pin": "42",
  "attempts_remaining": 5
}
```

`attempts_remaining` is advisory, and exists so a tutor can stop a student
guessing in a room where they are trying to learn. The lockout itself is the
API's: a ceiling counted on a device is one a student clears by reinstalling the
app.

### Starting a session

Starting is reachable **only** through `verify-pin`. `POST
/v1/sessions/{id}/transition` used to accept a `pin` field and check it inline
with no attempt counter, which made all 100 candidates walkable without touching
the cooldown; it now refuses `in_progress` and points here. One path means the
ceiling cannot be circumvented.

## Ratings

One rating per (rater, session). A second submission from the same rater
**updates** the existing row and adjusts the tutor's running total rather than
counting the change twice, so the route returns 201 either way and the body is
the rating that now stands. Ratings exist only for `completed` sessions.

### `GET /v1/ratings/me`

The caller's own aggregate: average, total, count, recent ratings, and per-unit
endorsement counts. Returns zeroed counters for a user with no profile and
**does not create one** — a `GET` must not change state, or a student who merely
opened the screen would be handed a tutor standing.

### `GET /v1/ratings/me/recent`

The last 20 ratings the caller has received.

### `POST /v1/ratings/{session_id}`

`{"score": 1-5, "feedback_text": "...", "endorsed_course_unit_ids": ["..."]}`.
201 with the rating.

`endorsed_course_unit_ids` is optional and is **not** part of the score. It
records "this tutor knows this unit" — a claim about subject coverage that is
stored separately in `unit_endorsements` and is never read when promotion is
computed. Only the session's own `course_unit_id` may be endorsed; any other
unit is a 422, because a session is evidence about one unit and no more.
Submitting a corrected rating replaces the rater's previous endorsements for
that session rather than accumulating them.

Either party may rate a completed session. Only the session's **tutor** has
standing to move: a tutor rating their tutee stores the feedback and leaves
every tutor counter untouched, and does not create a `Tutor_Profile` for the
student.

Declared after the literal `/me` routes above because FastAPI matches in
declaration order.

## Incentives

### `GET /v1/incentives/certificate`

The caller's own certificate eligibility: `certified_minutes` and the
`required_minutes` the university requires. *Auth.*

`required_minutes` is configuration, not a constant, and it is returned with the
answer so the client renders the number the server will actually judge against.
A client that hardcodes the threshold shows a tutor who is two hours short a
progress bar that says they are done, and the failure lands on them at the moment
they are relying on it.

## Health

### `GET /health`

`{"status": "ok"}`. Deliberately does **not** touch the database — a liveness
probe that fails when Postgres is briefly unavailable will restart the process,
turning a database blip into an outage.

## Data model notes

**An account exists before it has a name.** `users.full_name` is nullable, and
`needsOnboarding` on the client is `full_name` null-or-blank **or** `university_id`
null. A nameless account is not an error state; it is the state a student is in
between finishing sign-up and finishing the wizard.

**`User` and `UserResponse`** differ in what they expose. `UserResponse` has no
`password_hash` and no `password_hash` field exists anywhere in the schemas
package; adding the attribute is one line and nothing fails until someone reads a
payload. `UserResponse` also has no consent timestamp, because another user's
consent is not the caller's to see.

[rfc9457]: https://www.rfc-editor.org/rfc/rfc9457
