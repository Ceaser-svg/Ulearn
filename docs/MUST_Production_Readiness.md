# MUST Pilot Production Readiness

This is the launch gate for the closed MUST pilot. It records what can be
verified in the repository and what requires a staging environment or a MUST
decision. A green local test suite alone is not a production approval.

## Verified in the hardening pass

- [x] Backend Ruff `check` and `format --check` pass.
- [x] Backend suite passes on in-memory SQLite: 543 passed.
- [x] Migrations build the schema on an otherwise empty database
      (`alembic upgrade head`), `alembic check` reports no drift from the models,
      and `alembic downgrade base` followed by `upgrade head` succeeds.
- [x] Registration rate limiting charges every hash-reaching attempt, including
      duplicates and the lost race, and leaves pre-hash denials free. A
      deterministic white-box race test replaces the flaky concurrent one.
- [x] `429` responses carry `Retry-After` and `errors.retry_after_seconds`, and
      the client maps them to a countdown that withholds retry until the wait
      elapses rather than reporting an unknown error.
- [x] Every formatted log record is redacted of credential-shaped values,
      including the rendered SQLAlchemy traceback. The leak was reproduced
      against PostgreSQL before the control existed.
- [x] Every request carries one `X-Request-ID`, validated when supplied inbound,
      echoed in the response, and attached to every log record for that request,
      including the unhandled-error path.
- [x] Flutter mobile `analyze` passes and the suite passes (431 tests).
- [x] Admin web `analyze` passes and the suite passes (42 tests).
- [x] CI runs backend SQLite and PostgreSQL jobs, applies and checks migrations,
      runs frontend and admin-widget tests, builds the web target, and asserts
      the Android release-signing gate fires without material while debug still
      builds.
- [ ] Container image: `backend/Dockerfile` and `backend/.dockerignore` are
      written, but the image was **not built** in this environment because the
      sandbox has no outbound network to a package index. The Dockerfile parses
      and its stages execute up to the dependency install; the install and a
      container smoke test remain to be run where the network is available.

## PostgreSQL suite status

The full suite passes repeatedly against a real PostgreSQL, including runs of
the current tree with the request-id and rate-limit changes. The suite builds
its own schema from the models with `create_all`, so it cannot detect a
migration that disagrees with them; the scratch-database `alembic` checks above
close that specific gap.

An intermittent full-suite failure was observed once historically, at roughly
one in fifteen runs, after a genuinely flaky concurrent test had already been
replaced with deterministic coverage. No traceback was captured, and it has not
been reproduced since. It is recorded as **unexplained, not resolved**: a
reproduction is the only thing that would close it, and until then the default
suite is treated as trustworthy but not proven stable.

## Required staging evidence

- [ ] Build a PostgreSQL database from empty using `alembic upgrade head`,
      then run `alembic check`, in the target environment. Proven on a scratch
      database locally; not yet on the deployed one.
- [ ] Exercise registration, onboarding, matching, tutor response, session
      completion, and mandatory rating through the real deployed router.
- [ ] Repeat tutor response, session completion, rating, and token refresh
      requests to verify idempotency and safe concurrency behavior.
- [ ] Run the seeded MUST cohort acceptance script on representative Android
      devices, including an intermittent/low-bandwidth profile.
- [ ] Perform a backup and restore rehearsal and record the recovery point and
      recovery time. The managed-cloud phase owns this evidence.
- [ ] Verify HTTPS, CORS, secret configuration, log redaction, request-id
      propagation, and alert delivery in a non-production environment.
- [ ] Build and run the container image, and confirm a non-root process serves
      `/health` while `/ready` reflects database access.
- [ ] Complete a security/privacy review before issuing pilot invitations.

## Current blockers

The following are intentionally not represented as passing:

1. Managed-cloud provider, domain, production PostgreSQL, secrets, migration
   job, backups, restore, rollback, CI/CD, metrics, and alerts remain deferred to
   `chore/managed-cloud-operations`.
2. MUST has not yet supplied the final launch course-unit list, tutor cohort,
   operator contacts, safeguarding owner, support channel, privacy wording, or
   retention/deletion decisions.
3. Registering a duplicate address still returns a distinct `409`, which is an
   address-enumeration signal. Hiding it needs an email-confirmation or
   equivalent flow, which is a product decision, not a client change.
4. Manual tutor-standing adjustment requires an auditable admin workflow before
   operators can use it.
5. The certificate-duration floor is a MUST policy decision and is not encoded.
6. Device, low-bandwidth, backup/restore, and deployed-router evidence cannot be
   claimed from local tests.

## Release decision

The pilot is **not approved for production access** until every staging evidence
item is attached to a dated run and every current blocker is either resolved or
explicitly accepted by the MUST launch owner. Update this file as evidence
arrives rather than replacing unchecked items with informal assurances.
