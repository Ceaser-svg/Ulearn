# PeerPass — Agent & Contributor Guide

This file is the **source of truth** for how code is written in this repository.  
Any agent (or human) working here must follow it. Prefer a smaller, correct change over a large, incomplete one.

---

## 1. Project context

PeerPass is a mobile-first peer tutoring network for university students. It matches tutees with verified peer tutors, records sessions, and tracks tutor standing through ratings.

**Read before changing behavior:**

| Document               | Why it matters                                      |
| ---------------------- | --------------------------------------------------- |
| `README.md`            | Product scope and local setup                       |
| `docs/architecture.md` | System boundaries, data model, matching, validation |
| `docs/MVP_Brief.md`    | What is in / out of the current MVP                 |
| `docs/Contribution.md`  | Workflow, standards, review rules                   |

Do not invent product rules. Matching, grade gates, rating thresholds, and role transitions are defined in architecture and the backend — not in Flutter widgets.

---

## 2. Agent team model (how work is run)

Treat the agents on this project as a **small engineering team**, not a single chat that does everything.

### Roles

| Role                           | Who                                                                     | Responsibility                                                                                                                                                                               |
| ------------------------------ | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Lead engineer (main model)** | Primary agent in the session                                            | Owns the outcome. Plans, decides architecture, implements critical paths, reviews delegated work, runs final verification. Remains accountable for every change that lands.                  |
| **Specialist / sub-agents**    | Secondary agents (cheaper or narrower models, or parallel sub-sessions) | Execute bounded tasks: docs, boilerplate, repetitive refactors, test scaffolding, formatting, research of existing patterns. They do **not** set product policy or change domain invariants. |

### Lead engineer rules

1. **You are the brain.** You hold product context, architecture, and the definition of done. Sub-agents do not replace your judgment.
2. **Delegate to protect context.** Do not burn the main context window on low-leverage work. Push to sub-agents:
   - Documentation drafts and doc-only edits
   - Boilerplate (empty feature folders, model stubs, test shells)
   - Mechanical renames / formatting
   - “Find how X is done in this repo” research summaries
   - Generating first-pass tests from a clear spec you wrote
3. **Keep hard problems on the main agent.** Matching logic, validation/grade gates, rating → verification transitions, auth/security, schema changes, and any cross-feature design stay with the lead.
4. **Brief every sub-agent.** A sub-agent gets a tight brief: goal, files allowed to touch, constraints from this guide, and what “done” means. No open-ended “improve the app.”
5. **Review before merge into the main line of work.** Sub-agent output is a draft. The lead checks it against architecture, invariants, and tests before accepting it.
6. **One source of truth.** Sub-agents must not invent new folder layouts, state-management patterns, or product rules. If unsure, they stop and the lead decides.

### What to delegate vs keep

| Delegate (sub-agent)                       | Keep on lead (main agent)              |
| ------------------------------------------ | -------------------------------------- |
| `docs/` wording updates                    | Matching / competency / rating rules   |
| README / CONTRIBUTING polish               | API contract and schema design         |
| Feature folder scaffolding                 | Session lifecycle and role transitions |
| Repetitive model/DTO stubs                 | Security, auth, data privacy paths     |
| Test file shells from a written cases list | Final integration of a feature slice   |
| Locating existing patterns in the repo     | Cross-feature design decisions         |

### Context discipline

- Prefer a short plan + delegated tasks over one long monologue that touches every layer.
- After a large delegated batch, re-state the current goal and open risks in the main thread so the lead does not drift.
- If the main agent’s context is getting noisy, summarize decisions into a short note (or update the relevant doc) and continue from that — do not keep improvising on a polluted thread.

The lead remains **responsible for everything** that ships, including work produced by sub-agents.

---

## 3. Repository boundaries

| Path             | Role                                                                                                        |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| `frontend/`      | Flutter client. Feature-first. Canonical app.                                                               |
| `backend/`       | FastAPI service. HTTP in `api`, logic in `services`, persistence in `models`, transport types in `schemas`. |
| `backend/tests/` | Backend unit and integration tests                                                                          |
| `frontend/test/` | Mirrors `frontend/lib/`; `test/integration/` for end-to-end                                                 |
| `docs/`          | Architecture and project documentation                                                                      |
| `legacy/`        | **Reference only.** Not buildable. Do not add code here.                                                    |

---

## 4. Frontend architecture (strict)

```text
lib/
├── main.dart              # ProviderScope + runApp only
├── app/                   # MaterialApp.router, GoRouter, auth redirect
├── core/                  # Shared foundations — no feature knowledge
└── features/<name>/       # data/ + presentation/ only
```

### Per-feature layout

| Path                 | Role                                         |
| -------------------- | -------------------------------------------- |
| `data/models/`       | Wire DTOs for this feature’s endpoints       |
| `data/datasources/`  | Remote (and in-memory fake) data sources     |
| `data/repositories/` | Abstract contract **and** its implementation |
| `presentation/`      | Screens, widgets, Riverpod providers         |

### Hard rules

- **No client-side domain layer.** Matching, validation, grades, and ratings are owned by the backend. Client “domain” types would be pass-through noise.
- Shared types that several features need live in `core/models/` — not a loose `shared/` dumping ground.
- `core/` must **never** import from `features/`.
- A feature must **not** import another feature’s `presentation/`. Cross-feature reuse goes through the owning feature’s repository contract only.
- Business rules do **not** belong in widgets, providers that only format UI, or route handlers.

---

## 5. Backend architecture (strict)

| Layer           | Responsibility                                           |
| --------------- | -------------------------------------------------------- |
| `app/api/`      | HTTP routes, dependency injection, status codes          |
| `app/schemas/`  | Pydantic request/response models                         |
| `app/services/` | Business logic (matching, validation, sessions, ratings) |
| `app/models/`   | SQLAlchemy ORM                                           |
| `app/core/`     | Config, security, database session, exceptions           |

Do not put matching or grade logic in route handlers. Do not put HTTP concerns in services.

---

## 6. Domain invariants (non-negotiable)

These are product rules. Breaking them is a bug, not a style issue.

1. **Matching** must only propose tutors who pass competency + status checks for that unit.
2. **Competency** requires a declared grade of **B+ or higher** (unless an explicitly documented portfolio/manual override exists — not in MVP by default).
3. New tutors start as **Provisional**; **Verified** is earned via ratings, not self-claim.
4. A completed session **requires** a post-session rating before the quality loop is considered done.
5. Session records are the source of truth for hours and future certificate eligibility.
6. Academic data is sensitive: secrets only via environment variables, explicit consent where required, HTTPS in real deployments.
7. **Faculty scope.** A user's course units belong to their faculty, and so does every record derived from one: declared primary modules, declared competencies, and the tutor rail. The university silo filters (a record outside it is not in the list); the faculty silo *scopes* (the endpoint answers for exactly one faculty, so `GET /v1/academics/course-units` is authenticated while universities and faculties stay public). A tutor's **detail** screen is deliberately cross-faculty to any authenticated user — a student with a direct link must see who they are about to ask. Never let a client-supplied `subject_id` widen a scope the server set.
8. **A faculty that publishes no course units is a normal state**, not a fault. Four of the six seeded faculties are in it. Declared modules are a matching input and a precondition of *nothing*: never gate an account, a route, or a screen on having declared one, or such a student is locked out permanently.

---

## 7. How agents must work

The main agent operates as **lead engineer** (see §2). Plan on the main thread; delegate low-leverage work; keep critical logic and final review on the lead.

### Plan before large edits

For any change that touches more than ~2–3 files or changes behavior:

1. State the goal in one sentence.
2. List the files you will touch.
3. Note which invariants or tests apply.
4. Decide what the lead keeps vs what a sub-agent can draft.
5. Only then implement.

Do not “explore by rewriting.” Read the existing pattern in a neighboring feature and match it.

### Prefer small, verifiable steps

- One concern per change set (one feature slice, one bug, one refactor).
- After each meaningful step: code should analyze clean and relevant tests should pass.
- Do not accumulate a large unfinished pile of files and “fix it at the end.”

### Match existing patterns

- Copy structure from an existing feature that already works (auth, matching, sessions).
- Same naming, same folder roles, same error-handling style.
- Do not introduce a new state-management approach, folder convention, or HTTP client pattern without an explicit decision recorded in docs.

### Definition of done (every feature / PR-sized change)

A change is **not done** until all of the following are true:

- [ ] Behavior matches the MVP brief and architecture rules above
- [ ] Types are strong; no `dynamic` / untyped escape hatches without a comment
- [ ] Errors are handled narrowly (validation, auth, network, not bare `catch`)
- [ ] New or changed behavior has focused tests
- [ ] `flutter analyze` / `pytest` (as relevant) pass
- [ ] No drive-by refactors outside the stated goal
- [ ] Docs updated in the **same** change if a boundary or public behavior changed
- [ ] No secrets, `.env`, or credentials committed

### Definition of done (a full-stack feature slice)

The list above is per-change. A feature that spans the API and the app — the auth
screens, matching, sessions — is not done at "the backend tests pass". It is done
when the slice works from a cold start with nothing stubbed. Concretely, **all** of:

- [ ] Every layer the slice needs is real. A stub on the request path is not a
      deferred task; it is an unfinished feature. No `...` bodies, no `pass` in a
      service the UI calls, no fake datasource wired where the remote one belongs.
- [ ] The wire contract is exercised end to end: a real request through the real
      router, asserted on in a test. A unit test on a handler with a mocked
      dependency does not prove the route, the dependency wiring, or the auth
      guard work.
- [ ] The client's failure states are handled as deliberately as its happy path:
      validation, auth expiry, network loss, and a server error are all reachable
      in the UI and none of them shows raw exception text.
- [ ] No secret can reach a log. Checked by reading the diff for anything that
      prints a request body, a response body, a header, or a token.
- [ ] The database can be built from migrations alone on an empty database, and
      `alembic check` reports no drift against the models.
- [ ] Required settings have no defaults that make a missing secret survivable.
- [ ] `docs/api-reference.md` covers the new endpoints, and
      `docs/architecture.md` covers any decision a later contributor could
      otherwise re-litigate.
- [ ] Everything in section 9 of this guide runs green, not just `pytest`.

### Reporting validation honestly

Never state or imply that a check passed without running it. If a command could not
be run — no database available, a tool missing, a lockfile still generating — say
which one and why. "Tests pass" when only the SQLite suite ran against a service
that runs on PostgreSQL is a false claim about a security-relevant system, and it
is the exact class of defect the PostgreSQL job exists to catch.

### Explicitly forbidden

- Implementing business rules (matching, grade gates, rating thresholds) only on the client
- Creating a parallel “domain” layer in Flutter that duplicates backend logic
- Silent failure (empty catches, returning null where an error should surface)
- Giant unfocused diffs (“while I was here I also…”)
- Adding dependencies without a clear need
- Writing to `legacy/`
- Pushing to remote, or adding `Co-Authored-By` / attribution trailers
- Claiming “tests pass” without running them

---

## 8. Implementation standards

**Naming**

| Kind                | Convention                                |
| ------------------- | ----------------------------------------- |
| Dart / Python files | `snake_case`                              |
| Classes             | `PascalCase`                              |
| Methods / variables | `camelCase` (Dart), `snake_case` (Python) |
| Constants           | `UPPER_SNAKE_CASE`                        |

**Quality**

- Prefer explicit types over inference where it helps readability at boundaries.
- Prefer small pure functions in services over god-objects.
- UI should be dumb: display state, emit intents; logic lives in providers calling repositories, which call the API.
- Comments explain **why**, not what the next line obviously does.

**Tests that matter most**

- Matching eligibility (wrong unit, low grade, provisional vs verified)
- Grade boundaries (B+ in, B out)
- Rating thresholds and Provisional → Verified transitions
- Session status transitions (requested → accepted → completed → rated)

---

## 9. Validation commands

Run these before considering work complete.

**Backend**

```bash
cd backend
ruff check .
ruff format --check .
pytest
```

Default suite uses in-memory SQLite and must stay green that way (CI has no DB for the fast job).

Schema-sensitive changes also need a real PostgreSQL run (never point this at production data):

```bash
cd backend
PEERPASS_TEST_DATABASE_URL=postgresql+psycopg://user:pass@localhost:5432/scratch_db pytest
```

The test suite builds its schema from the models with `create_all`, so it cannot
detect a migration that disagrees with them. Migrations need their own check
against an **empty** database:

```bash
cd backend
alembic upgrade head   # from empty, not from a test database
alembic check          # no drift between the migrations and the models
alembic downgrade base && alembic upgrade head
```

`alembic check` against a database already carrying the schema is meaningless, and
`upgrade head` against one is a no-op that hides a broken migration. Use a scratch
database, drop it first, and read the output rather than the exit code alone.

**Dependencies**

`requirements.in` and `requirements-dev.in` are the source; the `.txt` files are
generated and hash-pinned:

```bash
cd backend
pip-compile --generate-hashes --strip-extras --output-file=requirements.txt requirements.in
pip-compile --generate-hashes --strip-extras --output-file=requirements-dev.txt requirements-dev.in
```

Expect tens of minutes, not seconds — see the comment at the top of
`requirements.in` for why. Do not hand-edit a generated `.txt`, and do not add a
dependency to a `.txt` directly; a `pip install` that updates it by hand produces
a file that no longer corresponds to the `.in` and silently drifts.

**Frontend**

```bash
cd frontend
flutter analyze
flutter test
```

Both analyze and test must be clean for frontend work.

---

## 10. Git workflow

| Branch prefix | Use for                           |
| ------------- | --------------------------------- |
| `feature/`    | New behavior                      |
| `fix/`        | Defect fixes                      |
| `docs/`       | Documentation only                |
| `refactor/`   | Structure change, no new behavior |
| `test/`       | Tests only                        |
| `chore/`      | Tooling / config                  |

**Commits** — conventional commits only:

Make sure that for any implement, you are working on a separate branch from main, the main branch should never be used to make any changes of any kind. If a different branch does not exist create the branch and then start working.

```text
feat: | fix: | docs: | style: | refactor: | perf: | test: | chore:
```

- Subject: lowercase start (unless proper noun), ≤ ~50 chars, imperative, no trailing period
- Body: explain **why** when it is not obvious
- One concern per commit; keep diffs reviewable
- Commit after each complete, verifiable step
- Update docs that the change invalidates in the **same** commit
- **Never push.** Maintainer publishes
- **Never** add `Co-Authored-By`, `Signed-off-by`, or other attribution trailers

Before every commit:

1. Run the relevant validation commands
2. `git status` shows only intended files

---

## 11. When stuck or unsure

1. Re-read `docs/architecture.md` and the relevant feature’s existing code.
2. Prefer the smallest change that preserves invariants.
3. If the product rule is unclear, stop and ask — do not invent matching or verification policy.
4. Do not “make it work” by weakening a grade gate, skipping a rating, or bypassing role checks.

---

**Maintainers expect agents and contributors to treat this file as binding.**  
Clean architecture + passing tests + respect for domain invariants = shippable work.
