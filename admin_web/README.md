# PeerPass Admin Web

The separate Flutter web console for MUST pilot operations.

## Local development

Start the backend first, then run:

```bash
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

The API URL is a build-time value. Production builds must provide the HTTPS
origin of the deployed PeerPass API:

```bash
flutter build web --release \
  --dart-define=API_BASE_URL=https://api.example.invalid
```

Only provisioned accounts with the backend `admin` role can sign in. The
console does not provide public admin registration or role assignment.

## Pilot surface

- **Users** shows the bounded, privacy-safe operational user list.
- **Audit log** shows append-only records of privileged admin actions, each
  naming the operator who performed it.
- **Competency review** is the console's only write: verifying or rejecting a
  pending competency claim.
- **Tutor standing** shows privacy-safe tutor aggregates.

### Competency review

Each row carries the context a decision needs: the tutor, the unit, the grade
with the bar it has to clear, the server's verdict on that bar, the status, when
it was submitted, and any previous refusal reason.

- **The filter** narrows to one status and is applied by the API, so the count
  in the pager is the count that matches. Changing it returns to the first page.
- **Only `pending` rows offer actions.** `verified` and `rejected` are closed to
  review, because the backend owns the status transition and a button that cannot
  succeed is worse than no button. A rejected tutor may resubmit, which returns
  the claim to `pending`.
- **A grade under the bar is flagged before the attempt.** Verification would be
  refused by the API, so the row says so rather than letting the operator read the
  evidence first and then discover it.
- **A university with no grading scale loaded is a normal state.** The row shows
  no bar and says so; nothing can be verified for that university until a scale
  is loaded.
- **A status this build does not know is shown as the server spelled it** and is
  not offered for review. A client cannot know what transition it does not have a
  name for, and MUST invariant 2 is not a console setting.

### Evidence is not in the console

`evidence_reference` is what the tutor said they are submitting against — a
reference they supplied, such as a transcript held by the faculty office. The
console cannot open, preview, or download it. Operators obtain and read the
evidence through MUST's approved channel and check it against the row; see
`docs/MUST_Pilot_Operations.md` for the procedure.

Loading, empty, server-error, and retry states are explicit, and an empty queue
says which question it is answering so a filtered queue that matches nothing is
not read as a broken console. The console does not display passwords, refresh
tokens, consent timestamps, competency evidence, or internal database identifiers.

### Layout

Each list is a table on a wide window and a labelled card below a breakpoint —
`720` for most lists, `1100` for the review queue, whose seven columns stop being
readable well before they stop fitting. A narrow window pairs each value with its
column heading in its own semantics node, including cells that are widgets rather
than text, so a status pill is announced as a status.
