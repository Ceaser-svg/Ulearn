# PeerPass — Flutter client

The mobile client for PeerPass, a peer-to-peer academic support network. See
[the architecture document](../docs/architecture.md) for system boundaries and
[the repository guide](../AGENTS.md) for contribution rules.

## Requirements

| Tool           | Version                       |
| -------------- | ----------------------------- |
| Flutter        | `>=3.47.0` (pinned in pubspec) |
| Dart           | `^3.13.1` (implied by Flutter)  |
| Android SDK    | 36.x                          |

Check with `flutter doctor`. The `flutter` constraint in `pubspec.yaml` means an
older SDK fails at `pub get` with a clear message rather than later on a missing
API.

## Targets

Android, iOS, and web. Desktop runners were removed: the pilot is mobile, and
each runner is a build surface that has to keep compiling. Web is retained as a
stakeholder demo target that needs no device.

## Running

```bash
flutter pub get
flutter run                                   # attached device or emulator
flutter run --dart-define=API_BASE_URL=https://api.example.org
```

### The API base URL

There is no hardcoded deployment host. `AppConfig` reads `API_BASE_URL` from
`--dart-define`; web falls back to `http://localhost:8000` and Android
emulators fall back to `http://10.0.2.2:8000` for local development.
`--dart-define` is resolved by the compiler, so switching environments means
rebuilding rather than flipping a setting at runtime.

`10.0.2.2` is the Android emulator's alias for the host machine's loopback.
`localhost` inside the emulator is the emulator itself, which is the single most
common cause of a client that works on web and cannot reach a local API on
Android. For a physical device, pass your machine's LAN address explicitly.
For a browser demo against a local backend, use a fixed web port and configure
`CORS_ORIGINS` for that exact origin:

```bash
flutter run -d chrome --web-port 8080 \
  --dart-define=API_BASE_URL=http://localhost:8000
```

The backend must be started with `CORS_ORIGINS=http://localhost:8080`.

Secrets are never compiled into the client. The API holds no secrets; the
access and refresh tokens are held in `flutter_secure_storage`.

## Validation

```bash
flutter analyze
flutter test
flutter test --coverage
```

`flutter analyze` is the gate CI enforces. It runs `very_good_analysis`, with
four rules relaxed in `analysis_options.yaml` and the reasoning recorded there.

## Layout

Feature-first, two layers per feature, because matching, validation, grade, and
rating rules are owned by the backend:

```text
lib/
├── main.dart          # ProviderScope and runApp only
├── app/               # MaterialApp.router, GoRouter, auth redirect guard
├── core/              # shared foundations, no feature knowledge
└── features/<name>/   # data/ and presentation/
```

`core/` must never import from `features/`. A feature must not import another
feature's `presentation/` layer; cross-feature reuse goes through the owning
feature's `data/repositories/` contract.

`test/architecture/dependency_rules_test.dart` enforces those three boundaries
by reading the source tree, so a violation fails `flutter test` rather than
waiting for review.

### The shell

`main.dart` is the composition root and nothing else: it overrides
`authRepositoryProvider` with the implementation to use, so swapping the
in-memory auth for the real API is a one-line change. `app/router.dart` holds
the routes and the redirect guard.

The guard is one pure function, `_redirectFor`, that maps an auth status and the
current location to a destination. Keeping it free of a router, a widget tree,
and a session means the rule is testable directly. It holds the app on
`SplashScreen` while the status is `unknown`, because a returning tutor who is
flashed sign-in for one frame reads as being logged out.

### The core layer

| Path                | Contents                                                              |
| ------------------- | --------------------------------------------------------------------- |
| `config/`           | `AppConfig`: build-time configuration from `--dart-define`             |
| `constants/`        | `AppDimens`: the spacing and radius scale                              |
| `error/`            | `Failure`: a sealed hierarchy the UI renders instead of transport types |
| `models/`           | Types genuinely shared by several features                             |
| `network/`          | `buildApiClient`, the auth interceptor, and error classification       |
| `storage/`          | `TokenStore` (keystore-backed) and `PreferencesStore` (plaintext)      |
| `theme/`            | `AppTheme`: Material 3 themes from a provisional seed                 |
| `utils/`            | `Validators`: shape checks that spare a round trip                     |
| `widgets/`          | `FailureView`, `EmptyView`, `LoadingView`, `ContentWidthLimiter`       |

Three conventions are worth knowing before adding to it:

- **Failures, not exceptions.** `DioException` and `SocketException` stop at
  `network/`. Everything above renders a `Failure`. The hierarchy is sealed, so
  adding a variant is a compile error until every presentation site handles it.
- **No business rules.** `GradingScale` and `Grade` carry no competency
  thresholds and `Validators` carry no policy. Those rules live in the API. A
  client-side rule that disagrees with the server is a bug, not a shortcut.
- **Tokens never touch `shared_preferences`.** `TokenStore` is keystore-backed;
  `PreferencesStore` is explicitly for non-sensitive values only.

Tests mirror `lib/`. `test/integration/` is reserved for end-to-end runs of the
real app.

### What is not built yet

`features/auth/` and `features/home/` hold their data contracts, a provider, and
a placeholder screen. Sign-in, registration, and the home content are not
implemented, and no feature carries behaviour yet. The remaining five features
have no directory: they are created when their first screen is written, so that
an empty tree is never mistaken for finished work.

## Known deferrals

- **Application id.** `com.peerpass.app` is a placeholder pending a registered
  domain. It is free to change until a keystore is signed or a store listing is
  created; after that it is effectively permanent. Update
  `android/app/build.gradle.kts` (`namespace` and `applicationId`), the Kotlin
  `MainActivity` package, and the iOS `PRODUCT_BUNDLE_IDENTIFIER` together — a
  mismatch between namespace and applicationId fails the Android build.
- **Branding.** The web manifest still carries the Flutter template blue. It
  moves when the brand seed colour is set.
- **Launcher icon.** Still the default Flutter mark.
