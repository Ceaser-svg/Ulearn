# MUST Pilot Operations

This runbook defines the manual controls for the closed MUST pilot. It is
part of the launch contract: operators must resolve the items marked
**MUST SUPPLY** before inviting real students.

## Operating roles

MUST appoint one primary operator and one backup operator. The primary
operator reviews tutor evidence, handles safety and dispute escalations, and
owns the daily metrics check. The backup can perform the same actions when
the primary is unavailable. **MUST SUPPLY:** names, phone numbers, and the
support mailbox for both roles.

Admin accounts are individually assigned, use unique credentials, and are
removed when staff leave the pilot. Operators must not share accounts or
export user lists to personal devices.

## Cohort and invitation

1. Confirm the six-unit provisional catalogue against MUST's approved launch
   list before invitations are sent.
2. Record each invited student's and tutor's consent and invitation source in
   the approved pilot register.
3. Invite only the agreed cohort of 10–20 tutors and the approved student
   group. Do not enable public self-registration for the pilot.
4. Remove access promptly when a participant withdraws or is no longer
   eligible.

The register contains the minimum necessary identity and status information.
It must not contain passwords, tokens, transcript images, or copied evidence.

## Tutor evidence and standing

Operators review each pending competency in the admin console against the
submitted evidence and the selected course unit. A competency is accepted
only when the evidence supports a B+ (4.5) or higher result for that unit.
Evidence is not copied into audit events. Rejection must include a clear,
non-sensitive reason that the tutor can act on.

New tutors remain **Provisional** until the backend rating rules promote them.
Operators must not manually claim that a tutor is Verified. Any manual
standing adjustment requires a documented reason, a second-operator review,
and an audit event; the implementation of that workflow is a launch blocker
until available in the admin API.

## Session support and disputes

Participants report a missed session, unsafe conduct, impersonation, academic
misconduct, or a rating dispute through the MUST support channel. The
operator records the report ID, affected session, received time, severity,
owner, and resolution without copying sensitive chat or evidence into notes.

- **Urgent safety concern:** pause further matching for the involved account,
  preserve the minimum relevant records, and escalate immediately to MUST's
  safeguarding owner. **MUST SUPPLY:** safeguarding contact and response
  target.
- **Academic or identity concern:** pause the competency or account pending
  review; do not disclose the reporter's identity unnecessarily.
- **Missed session or ordinary dispute:** contact both parties, record the
  outcome, and escalate repeated patterns.
- **Rating abuse:** do not delete or rewrite ratings informally. Escalate
  suspected retaliation, coordinated ratings, or repeated manipulation for
  an auditable decision.

## Privacy, consent, and retention

Before access, participants receive the pilot privacy notice, purpose of
processing, data categories, withdrawal route, and support contact. Consent
must be recorded where required by MUST policy. Withdrawal stops new matching
and starts the account/data handling procedure; it is not treated as a
negative standing signal.

Academic records and evidence are sensitive. Operators access them only for
the review purpose, use HTTPS, and do not download them unless MUST's approved
procedure requires it. **MUST SUPPLY:** retention periods, deletion owner,
and the approved privacy notice/consent wording. No production launch should
claim these values are finalized while they are outstanding.

## Daily checks and metrics

The primary operator checks readiness, failed requests, pending competency
reviews, unresolved safety/dispute reports, and admin audit events daily.
The pilot dashboard or exported report should track:

- invitation-to-onboarding activation and onboarding completion;
- match rate and tutor response rate;
- accepted-to-completed session rate and rating completion;
- average rating and repeat dispute/rating-abuse reports;
- unresolved incidents, median response time, and account withdrawals.

Metrics are aggregated for reporting and must not expose individual academic
records. Operators record the date, cohort denominator, and any known data
limitations with each report.

## Hosting the apps

Two separate clients ship to students: the Flutter app, and a web build that
routes on the client. Each needs its own host and each fails in its own way.

**The Flutter web build needs an SPA rewrite, and nothing in this repository can
provide it.** Because routing happens in the browser, a static host that serves
files literally will 404 on every deep link and every refresh — `/sessions/123`
requests a directory that does not exist. The host must serve `index.html` for
any path that is not a real file:

| Host                     | Configuration                                                        |
| ------------------------ | -------------------------------------------------------------------- |
| nginx                    | `try_files $uri $uri/ /index.html;`                                    |
| Netlify, Vercel, Firebase| rewrite `/*` to `/index.html`                                          |
| Apache                   | `FallbackResource /index.html`                                        |
| GitHub Pages             | a `404.html` that redirects to the base path                          |

Symptom to recognise: the app loads at `/` and works, but any refresh or shared
link returns the host's 404 page. The fix belongs to the host. Do not work
around it by creating real directories in `frontend/web/` — that produces a site
where only the routes that happen to have a directory survive, which is a harder
outage to diagnose than the original.

Verify the rewrite after every host change, before pilot: open a deep route such
as `/sessions/123` directly in a fresh browser session and confirm it renders the
app rather than a 404.

**Android release builds need signing material that is not in the repository.**
`android/key.properties` is git-ignored and read at build time; the four values
may equally come from the environment. A build with none of them fails on
purpose. Never let it fall back to the debug key: a release APK signed with the
debug key installs, and then can never be updated, because the store rejects
every later build for a changed signing identity. Losing that key means losing
the listing, so back up the keystore and its passwords somewhere the team can
reach them, separately from the code.

## Launch checklist

- [ ] MUST confirms the launch course units and tutor cohort.
- [ ] Primary/backup operators and safeguarding/support contacts are supplied.
- [ ] Privacy notice, consent, withdrawal, and retention decisions are approved.
- [ ] Every invited tutor has a review owner and evidence status.
- [ ] Admin accounts are tested; audit events are visible.
- [ ] A support and dispute rehearsal has been completed.
- [ ] The web host's SPA rewrite is configured and verified on a deep route.
- [ ] The Android release keystore is backed up and reachable by its owners.
- [ ] Managed-cloud deployment, backup, restore, and rollback gates are
      completed separately; this document does not mark them complete.
