"""Application configuration.

Every value that differs between a developer's machine, CI, and a deployment
arrives from the environment. Nothing here has a default that would let the
service start in a state nobody intended: a missing database URL, a missing
signing key, or a missing token pepper is a startup failure, not a warning,
because an API that boots without a signing key will happily issue tokens
nobody can revoke, and one that boots without a pepper can be checked offline
against a stolen database.

Three separate secrets, deliberately:

- `jwt_secret` signs tokens. Rotating it signs every user out unless the old
  key is kept in `jwt_previous_secrets`.
- `token_pepper` hashes refresh and verification tokens. Rotating it also signs
  every user out, because no stored hash matches afterwards.
- `database_url` frequently embeds its own credentials.

Collapsing any two of them into one would mean one rotation takes out two
independent protections at the same time.
"""

from functools import lru_cache
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

#: A list setting read from the environment as a plain string.
#:
#: `NoDecode` is what makes that work. By default pydantic-settings treats a
#: `list[...]` environment variable as JSON and calls `json.loads` on it before
#: any validator runs, so `CORS_ORIGINS=a,b` fails with a JSON parse error and
#: an empty value fails with one too -- the parse happens first, so a
#: `mode="before"` validator never gets the chance to accept the friendly form.
#: `NoDecode` turns that off and hands the raw string to the validator below.
PlainStringList = Annotated[list[str], NoDecode]


class Settings(BaseSettings):
    """Runtime settings, resolved from the environment or a local `.env`."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- Deployment ---------------------------------------------------------

    environment: Literal["development", "staging", "production"] = Field(
        default="development",
        description=(
            "Which deployment this process is. Exists so that the settings that "
            "are only safe in development can be refused by construction rather "
            "than by a comment asking nobody to set them. Defaults to "
            "`development` so a fresh checkout runs locally without ceremony; a "
            "real deployment has to say so."
        ),
    )

    # --- Database -----------------------------------------------------------

    database_url: str = Field(
        description=(
            "SQLAlchemy URL for the primary database. Use the "
            "`postgresql+psycopg` driver, which is async-capable."
        )
    )

    database_echo: bool = Field(
        default=False,
        description=(
            "Log every SQL statement, with its bound parameters. Allowed only "
            "when `environment` is `development`; refused otherwise."
        ),
    )

    @model_validator(mode="after")
    def _refuse_development_only_settings(self) -> Settings:
        """Make the dangerous knobs unrepresentable outside development.

        `database_echo` logs statements *with their bound parameters*, so the
        INSERT that creates an account is logged with the student's email
        address and password hash in cleartext, and the SELECT that signs one in
        is logged with the submitted address. On a platform that collects stdout
        that is a durable copy of the credential database in whatever log store
        the operator happens to use, with whatever retention and access policy
        that store has.

        A warning in the field description does not prevent it, because the
        failure mode is a single `DATABASE_ECHO=true` in a deployment manifest
        that nobody re-reads. Refusing to start is visible in the deploy log in
        a way a comment never is.
        """
        if self.database_echo and self.environment != "development":
            raise ValueError(
                "database_echo logs SQL with bound parameters, including email "
                f"addresses and password hashes, so it is refused when "
                f"environment is {self.environment!r}. Set environment to "
                "'development' to run with statement logging."
            )
        return self

    # --- Auth ---------------------------------------------------------------

    jwt_secret: str = Field(
        min_length=32,
        description=(
            "Primary signing key for access and refresh tokens. Must be at "
            "least 32 characters."
        ),
    )

    jwt_previous_secrets: PlainStringList = Field(
        default_factory=list,
        description=(
            "Retired signing keys, accepted for verification only. Rotating "
            "`jwt_secret` without listing the old key here invalidates every "
            "issued token; listing it lets existing tokens age out. Remove a "
            "key from this list once nothing signed with it can still be valid."
        ),
    )

    jwt_algorithm: str = Field(default="HS256")

    token_pepper: str = Field(
        min_length=32,
        description=(
            "Server-side pepper for hashing refresh and email-verification "
            "tokens. Distinct from the signing key so the two can be rotated "
            "independently. Rotating this signs out every session, because no "
            "stored token hash will match afterwards."
        ),
    )

    access_token_ttl: int = Field(
        default=15,
        ge=1,
        description="Access token lifetime in minutes. Kept short so that "
        "rotation is exercised rather than avoided.",
    )

    refresh_token_ttl: int = Field(
        default=30,
        ge=1,
        description="Refresh token lifetime in days.",
    )

    # --- Password hashing ---------------------------------------------------

    password_hash_memory_kib: int = Field(
        default=19_456,
        # The floor is enforced in configuration, not only in a test, so that it
        # cannot be lowered by an environment variable. A config value is
        # invisible in review; changing a constant here is not. Lowering this
        # below the OWASP minimum removes the memory-hardness that is the entire
        # reason for using Argon2, and it has to be a deliberate edit to code.
        ge=19_456,
        description=(
            "Argon2id memory cost in KiB. 19456 is the OWASP floor. Raising it "
            "is not a migration: every stored hash records the parameters it "
            "was made with, and a successful sign-in rewrites any hash made "
            "under weaker settings."
        ),
    )

    password_hash_time_cost: int = Field(
        default=2,
        ge=2,
        description="Argon2id passes over memory. The OWASP floor is 2.",
    )

    password_hash_parallelism: int = Field(
        default=1,
        ge=1,
        description=(
            "Argon2id lanes. One lane is the OWASP floor and is the right choice "
            "on a small instance: every additional lane multiplies peak memory "
            "per concurrent verification."
        ),
    )

    password_hash_max_concurrency: int = Field(
        default=4,
        ge=1,
        le=64,
        description=(
            "How many password hashes may be computed at once, per process. "
            "This is a memory setting, not a throughput one: each concurrent "
            "hash holds roughly `password_hash_memory_kib` of resident memory "
            "for its duration, so the ceiling is what stops a burst of sign-in "
            "attempts from becoming an out-of-memory kill instead of a slow "
            "response. Beyond this, hashing queues. Raise it on an instance "
            "that has the RAM for it; the calculation is "
            "max_concurrency * memory_kib against the container's limit."
        ),
    )

    # --- Rate limiting ------------------------------------------------------
    #
    # Policy, not mechanics. The limiter itself is one mechanism; these numbers
    # are the decisions a deployment has to make about its own users, and they are
    # separated here so that changing one does not mean reading the limiter's
    # source to find out what it does.
    #
    # The account and IP ceilings differ by roughly 4x, and the reason is worth
    # stating because it looks like an inconsistency otherwise. A university
    # campus puts thousands of students behind one public address, so an IP
    # ceiling low enough to stop an attacker is also low enough that one hall
    # locking each other out of their own sign-in form is a real outcome. The
    # account ceiling is per-student and can therefore be strict; the IP ceiling
    # is shared infrastructure and cannot.

    auth_login_max_attempts: int = Field(
        default=5,
        ge=1,
        le=100,
        description=(
            "Wrong passwords before one account is locked out. Per account, so "
            "this is a statement about a single student, and 5 is low on purpose."
        ),
    )

    auth_login_lockout_seconds: int = Field(
        default=900,
        ge=1,
        description="How long a locked-out account stays locked.",
    )

    auth_login_ip_max_attempts: int = Field(
        default=20,
        ge=1,
        le=1000,
        description=(
            "Wrong passwords from one client address before that address is "
            "throttled. Higher than the per-account ceiling because a campus "
            "NAT shares one address across many students; see the section note."
        ),
    )

    auth_login_ip_lockout_seconds: int = Field(
        default=900,
        ge=1,
        description="How long a throttled client address stays throttled.",
    )

    auth_register_ip_max_attempts: int = Field(
        default=50,
        ge=1,
        le=1000,
        description=(
            "New accounts from one client address per lockout period. "
            "Registration is the endpoint an attacker wants for denial of "
            "service: each accepted sign-up costs a full Argon2 hash, so this "
            "is the ceiling on how much CPU one address can buy. It is much "
            "higher than the sign-in ceiling because legitimate registrations "
            "are genuinely bursty at the start of term, and a NAT means they all "
            "arrive from one address."
        ),
    )

    auth_register_ip_lockout_seconds: int = Field(
        default=3600,
        ge=1,
        description="How long registration is throttled for one client address.",
    )

    trusted_proxy_hops: int = Field(
        default=0,
        ge=0,
        le=10,
        description=(
            "How many reverse proxies sit in front of this process. 0 means "
            "trust no proxy header at all and use the socket address. This "
            "number is a security setting with no safe default, because both "
            "directions are dangerous and they fail differently. Trusting a "
            "header nobody set: an attacker adds their own `X-Forwarded-For` "
            "and gets a fresh rate-limit identity per request, so the IP limit "
            "does nothing. Trusting too few hops when a proxy is actually "
            "present: every request looks like it came from the proxy, so the "
            "entire user base shares one counter and one student guessing "
            "wrong locks out the campus. Count the proxies exactly. See "
            "`app.services.rate_limit.client_ip`."
        ),
    )

    # --- Transport ----------------------------------------------------------

    cors_origins: PlainStringList = Field(
        default_factory=list,
        description="Allowed browser origins. Empty by default: the pilot is a "
        "mobile client, and an accidental wildcard here would expose the API "
        "to any site a student visits.",
    )

    #: Hours of completed tutoring a tutor must accumulate to be issued a
    #: certificate, in minutes. The default is 40 hours.
    #:
    #: Configuration rather than a constant beside `PROMOTION_MIN_SESSIONS` in
    #: the rating service, and the reason is who changes it. Promotion is a
    #: quality rule an engineering decision should be able to defend in review;
    #: the certificate is an incentive a product owner tunes between pilots.
    #: A pilot that found 40 hours unreachable should be able to lower it with
    #: an environment variable rather than a code change and a migration.
    certificate_required_minutes: int = Field(
        default=2400,
        gt=0,
        description="Teaching minutes required for certificate eligibility.",
    )

    @property
    def jwt_verification_secrets(self) -> list[str]:
        """Every key a presented token is allowed to have been signed with.

        The primary key first, because it is the one new tokens are signed
        with. The rest are verification-only, which is what makes a rotation a
        configuration change rather than an outage.
        """
        return [self.jwt_secret, *self.jwt_previous_secrets]

    @field_validator("cors_origins", "jwt_previous_secrets", mode="before")
    @classmethod
    def _split_string_lists(cls, value: object) -> object:
        """Accept a comma-separated string as well as a JSON list.

        `CORS_ORIGINS` and `JWT_PREVIOUS_SECRETS` are both friendlier to set as a
        plain string in a shell or a container manifest than as embedded JSON.
        An empty or blank value means "none", so that a single-key deployment
        does not have to write `[]`.
        """
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    @field_validator("jwt_secret", "token_pepper")
    @classmethod
    def _reject_placeholder_secret(cls, value: str) -> str:
        """Refuse a secret that is obviously a placeholder.

        A committed `changeme` reaches production more often than anyone
        expects, and a weak signing key lets a third party mint tokens for any
        user.

        Matched as a prefix rather than the whole value, because the realistic
        shape is `changeme-change-me-in-production`, which satisfies the length
        rule and would otherwise sail through.
        """
        lowered = value.lower()
        if any(lowered.startswith(placeholder) for placeholder in _PLACEHOLDER_SECRETS):
            raise ValueError(
                f"secret starts with a placeholder ({lowered[:16]}...); "
                "supply a real key"
            )
        return value


_PLACEHOLDER_SECRETS = frozenset(
    {"changeme", "change-me", "secret", "replace", "replace-me", "development", "test"}
)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """The process-wide settings.

    Cached so the environment is parsed once and every module sees the same
    values; `get_settings.cache_clear()` exists for tests that need to vary it.
    """
    return Settings()  # type: ignore[call-arg]
