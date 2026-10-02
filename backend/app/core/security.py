"""Password hashing, opaque-token hashing, and token minting.

Deliberately the only module that knows how a credential becomes a stored hash
or a signed token. Services ask it for a hash or for a token; they never call
the Argon2 hasher or the JWT library directly, so either algorithm can change
without touching a service.
"""

import asyncio
import contextlib
import hashlib
import hmac
import secrets
import sys
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Any

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import (
    InvalidHashError,
    VerificationError,
    VerifyMismatchError,
)

from app.core.config import get_settings
from app.core.exceptions import AuthenticationProblem

TOKEN_TYPE_ACCESS = "access"
TOKEN_TYPE_REFRESH = "refresh"

#: OWASP's recommended Argon2id floor: 19 MiB, two passes, one lane.
#:
#: Argon2 is memory-hard, which is the point: it removes the parallelism that
#: makes GPU and ASIC cracking cheap against PBKDF2. The previous choice,
#: PBKDF2-HMAC-SHA256 at 600k iterations, was chosen when a compiled dependency
#: was a genuine operational cost. That reason has expired --
#: `argon2-cffi-bindings` publishes a single `abi3` wheel covering CPython
#: 3.10 through 3.15 on manylinux x86_64 and aarch64, macOS arm64, and Windows,
#: so there is no per-platform build step any more.
#:
#: These sit at the floor rather than above it because the pilot runs on a small
#: instance, and Argon2's cost is paid in resident memory per concurrent
#: verification rather than in CPU time. Raising the floor is not a migration:
#: every hash records the parameters it was made with, and
#: `password_needs_rehash` upgrades a stored hash on its owner's next
#: successful sign-in. Change the settings, and the fleet catches up on its own.
#:
#: Because the cost is memory rather than time, the ceiling on concurrent
#: verifications is a RAM calculation, not a CPU one. The rate limiter in
#: `app.core.rate_limit` has to respect it, or a burst of sign-in attempts
#: becomes an out-of-memory kill rather than a slow response.
_DEFAULT_MEMORY_COST_KIB = 19_456
_DEFAULT_TIME_COST = 2
_DEFAULT_PARALLELISM = 1

#: Bytes of entropy in a token that is emailed to a student and stored only as
#: a hash. 32 bytes is 256 bits, which is far past the point where guessing is
#: cheaper than the PBKDF2/Argon2 work the attacker would rather do elsewhere.
_OPAQUE_TOKEN_BYTES = 32

_PBKDF2_PREFIX = "pbkdf2_"


@dataclass(frozen=True, slots=True)
class TokenPair:
    """An access and refresh token, with the identifiers needed to rotate.

    `refresh_token_id` is the handle the server stores against the session. It
    is a separate opaque value rather than the token itself, so a stolen
    database yields no usable refresh token.
    """

    access_token: str
    refresh_token: str
    refresh_token_id: uuid.UUID
    refresh_expires_at: datetime


@lru_cache(maxsize=4)
def _password_hasher(
    memory_cost_kib: int, time_cost: int, parallelism: int
) -> PasswordHasher:
    """The Argon2id hasher for a given set of parameters.

    Cached on the parameters rather than globally, so that changing a setting
    produces a different hasher without anything having to invalidate a cache by
    hand. This matters in tests, which clear the settings cache and then need the
    hasher to follow.
    """
    return PasswordHasher(
        time_cost=time_cost,
        memory_cost=memory_cost_kib,
        parallelism=parallelism,
        hash_len=32,
        salt_len=16,
    )


@lru_cache(maxsize=4)
def _decoy_hash(memory_cost_kib: int, time_cost: int, parallelism: int) -> str:
    """A throwaway hash used to spend the same time as a real verification.

    Sign-in has to hash a password even when no account matches the email, or an
    attacker can tell a registered address from an unregistered one by how long
    the response took. Comparing that against a cached decoy costs the same
    resident memory and the same wall clock as comparing against a real hash.

    Generated from random bytes rather than a fixed string so it can never
    correspond to anybody's password, and so no two deployments share one.
    """
    hasher = _password_hasher(memory_cost_kib, time_cost, parallelism)
    return hasher.hash(secrets.token_urlsafe(_OPAQUE_TOKEN_BYTES))


def _hasher() -> PasswordHasher:
    settings = get_settings()
    return _password_hasher(
        settings.password_hash_memory_kib,
        settings.password_hash_time_cost,
        settings.password_hash_parallelism,
    )


def burn_password_verification() -> None:
    """Spend the cost of a real password verification, and discard the result.

    Called on the sign-in path when no account matched the submitted email, so
    that "no such user" and "wrong password" cost the same and leak the same
    amount. The comparison target is a random decoy that matches nothing.
    """
    settings = get_settings()
    decoy = _decoy_hash(
        settings.password_hash_memory_kib,
        settings.password_hash_time_cost,
        settings.password_hash_parallelism,
    )
    # The comparison is random, so a mismatch is the only reachable outcome.
    # `suppress` rather than `except: pass` because it names the two exceptions
    # it expects, which means an unexpected error here still propagates instead
    # of quietly turning the decoy into a no-op.
    with contextlib.suppress(VerifyMismatchError, InvalidHashError):
        _hasher().verify(decoy, secrets.token_urlsafe(_OPAQUE_TOKEN_BYTES))


def hash_password(password: str) -> str:
    """Hash a password for storage.

    Returns an Argon2id PHC string, which carries its own parameters:

        $argon2id$v=19$m=19456,t=2,p=1$<salt>$<digest>

    That self-description is what makes a parameter bump survivable. Nothing has
    to be migrated, because `password_needs_rehash` can read the old cost out of
    an old hash and tell it apart from one made under the current settings.

    There is deliberately no PBKDF2 fallback for reading existing hashes. The
    users table is empty, so no hash in the old format can exist, and a
    compatibility branch would be a timing oracle telling an attacker which
    accounts predate a migration -- for no recovery value, because there is
    nothing to recover.
    """
    return _hasher().hash(password)


def verify_password(password: str, stored: str) -> bool:
    """Check a password against a stored hash.

    Two rejections are deliberately not equivalent in cost. A wrong password
    against a well-formed hash has already paid for a full Argon2 verification,
    so it returns immediately. A malformed or missing hash has paid for
    nothing, so it burns a decoy comparison first -- otherwise a corrupt row
    would return faster than a wrong password, and that difference is readable
    from the outside.

    A stored value in the retired PBKDF2 format is treated as malformed, and so
    pays the burn. The two formats are distinguished only by a prefix, and
    refusing to recognise the old one is safer than recognising it.
    """
    if stored.startswith(_PBKDF2_PREFIX):
        burn_password_verification()
        return False

    try:
        _hasher().verify(stored, password)
    except VerifyMismatchError:
        # The full Argon2 verification ran; the password was simply wrong.
        return False
    except VerificationError:
        # A hash that names the right algorithm but cannot be parsed -- a
        # truncated value, a corrupt cost field. Parsing fails before any
        # Argon2 work happens, so this path has to pay the decoy comparison
        # itself or it returns measurably faster than a wrong password.
        burn_password_verification()
        return False
    except InvalidHashError:
        # Not a PHC string at all. Also a `ValueError`. Deliberately not caught
        # as one: a bare `except ValueError` would swallow a programming error in
        # the arguments, and this is a security boundary.
        burn_password_verification()
        return False

    return True


def password_needs_rehash(stored: str) -> bool:
    """Whether `stored` was made under parameters weaker than the current ones.

    True means the password was correct but the stored hash should be replaced.
    The service calls this after a successful verification and rewrites the row,
    which is how a raised floor reaches accounts gradually instead of all at
    once.

    Deliberately *not* wrapped in `to_thread`: it only parses the parameters out
    of the PHC string and compares numbers, so there is no Argon2 work to move
    off the loop.
    """
    if stored.startswith(_PBKDF2_PREFIX):
        return True
    try:
        return _hasher().check_needs_rehash(stored)
    except InvalidHashError:
        # An unreadable hash cannot be compared against anything. Reporting
        # "needs rehash" is the safe answer, because the rehash only happens
        # after a *successful* verification, which this hash cannot pass.
        return True


# ---------------------------------------------------------------------------
# Awaitable forms of the three functions above that do Argon2 work.
#
# Everything below is synchronous and stays that way. Argon2 is a blocking,
# memory-hard function and the correct answer to "how do I stop it blocking" is
# not to make it async -- it is to not run it on the thread whose job is to
# serve everyone else.
#
# Hashing sign-up or signing in cost ~50ms of CPU and 19 MiB of resident memory
# per call. On the event loop that is not 50ms for the one person signing in; it
# is 50ms during which *every* concurrent request in the process is not being
# served, including the requests that are not signing in. A handful of people
# signing in at once is the entire API stalling, and it looks in the metrics like
# general slowness rather than like the cause.
#
# `asyncio.to_thread` is the right size of tool here, and the GIL is not a
# problem: `argon2-cffi` computes in Rust and releases the GIL for the duration
# of the hash, so these threads genuinely run in parallel.
#
# The one thing `to_thread` does *not* do is bound how many run at once, and 19
# MiB each means unbounded concurrency is an out-of-memory kill. The rate
# limiter in `app.core.rate_limit` is what caps it.
# ---------------------------------------------------------------------------


async def hash_password_async(password: str) -> str:
    """[hash_password] without holding the event loop for the duration."""
    return await asyncio.to_thread(hash_password, password)


async def verify_password_async(password: str, stored: str) -> bool:
    """[verify_password] without holding the event loop for the duration."""
    return await asyncio.to_thread(verify_password, password, stored)


async def burn_password_verification_async() -> None:
    """[burn_password_verification] without holding the event loop.

    On the sign-in path this is the branch that runs when *no* account matched
    the address, so it was the one blocking call that a script probing for
    registered email addresses could trigger without knowing a single password.
    """
    await asyncio.to_thread(burn_password_verification)


def generate_opaque_token() -> str:
    """A URL-safe random token to send to a student by email.

    Returned once, to the caller, and never stored: only
    `hash_opaque_token` of it reaches the database. A 43-character string is
    short enough to survive a mail client and a paste, and long enough that
    guessing is not the cheapest way in.
    """
    return secrets.token_urlsafe(_OPAQUE_TOKEN_BYTES)


def hash_opaque_token(token: str) -> str:
    """Hash a high-entropy token for storage.

    HMAC-SHA256 under a server-side pepper, and deliberately *not* Argon2. The
    token already has 256 bits of entropy, so there is no dictionary to slow
    down; paying 19 MiB and two passes on every refresh and every verification
    would buy nothing and would make the sign-in path the slowest thing in the
    API.

    The pepper is a secret held only by this process. It turns a stolen database
    from "a list of hashes" into "a list of hashes that cannot be checked
    without also stealing the application", which is the same property the
    signing key gives the JWTs. Rotating it invalidates every stored token
    hash, which signs out every session -- so it is a deliberate act with a
    cost, not something to rotate on a schedule.
    """
    return hmac.new(
        get_settings().token_pepper.encode(),
        token.encode(),
        hashlib.sha256,
    ).hexdigest()


def verify_opaque_token(token: str, stored: str) -> bool:
    """Check a presented opaque token against a stored hash, in constant time.

    Both are 64 hex characters or neither matches, so a length check before the
    comparison leaks nothing.
    """
    if len(stored) != 64:
        return False
    return hmac.compare_digest(hash_opaque_token(token), stored)


def create_token_pair(*, subject: uuid.UUID) -> TokenPair:
    """Mint a fresh access and refresh token for a user.

    `subject` must be the user's **public id**, never the primary key. A JWT
    payload is base64, not encrypted, so the client can read every claim in it;
    a primary key in `sub` would put an internal database identifier in the
    hands of every client, every refresh, forever. The public id is the only
    identifier this project considers publishable.

    The access token deliberately carries no roles, no standing, and nothing
    else that can change while the token is valid. Those are read from the
    database on each request instead, so that suspending a tutor takes effect
    on their next request rather than whenever their token happens to expire.
    An access token's job is "which user, and until when"; anything that grants
    or withholds a privilege belongs somewhere that can be revoked.
    """
    settings = get_settings()
    now = datetime.now(UTC)
    refresh_expires_at = now + timedelta(days=settings.refresh_token_ttl)
    refresh_token_id = uuid.uuid4()

    return TokenPair(
        access_token=_encode(
            subject=subject,
            token_type=TOKEN_TYPE_ACCESS,
            ttl=timedelta(minutes=settings.access_token_ttl),
            now=now,
            claims={"jti": str(uuid.uuid4())},
        ),
        refresh_token=_encode(
            subject=subject,
            token_type=TOKEN_TYPE_REFRESH,
            ttl=timedelta(days=settings.refresh_token_ttl),
            now=now,
            claims={"jti": str(refresh_token_id)},
        ),
        refresh_token_id=refresh_token_id,
        refresh_expires_at=refresh_expires_at,
    )


def decode_token(token: str, *, expected_type: str) -> dict[str, Any]:
    """Verify a token and return its claims.

    Every failure raises [AuthenticationProblem], and the caller cannot tell
    from it whether the token was forged, expired, of the wrong type, or signed
    by a key this service has never heard of. Those cases are indistinguishable
    on purpose: each one that can be told apart is one an attacker can probe.

    Verification walks the whole configured key set, because rotating the signing
    key has to be possible without signing out every student on the network. The
    first key signs; the rest only verify.
    """
    for key in get_settings().jwt_verification_secrets:
        try:
            return _decode_with(token, key, expected_type=expected_type)
        except jwt.ExpiredSignatureError as exc:
            # Signature verification already succeeded, so this is the right
            # key and the only remaining problem is age. Trying the others would
            # be wasted work and would say nothing.
            raise AuthenticationProblem("Your session has ended.") from exc
        except jwt.InvalidSignatureError:
            # Wrong key. Try the next one.
            continue

    raise AuthenticationProblem("Your session is not valid.")


def new_uuid7() -> uuid.UUID:
    """A time-ordered UUID for primary keys.

    Chosen over a random v4 because the primary key is also the write-order
    index. Time-ordered values insert near the end of the B-tree instead of
    scattering inserts across it, which matters for the session log, the table
    that grows fastest and is read newest-first.

    Requires Python 3.14. `pyproject.toml` pins `requires-python` to match, and
    the check below turns a mismatch into a clear message at import time rather
    than an `AttributeError` on the first insert.
    """
    if not hasattr(uuid, "uuid7"):
        raise RuntimeError(
            "app.core.security.new_uuid7 requires Python 3.14 or later "
            f"(running {sys.version.split()[0]}). Every primary key "
            "in the database goes through this function, so the interpreter "
            "floor is load-bearing rather than a preference."
        )
    return uuid.uuid7()


def new_public_id() -> uuid.UUID:
    """A random UUID to expose to clients.

    Random rather than time-ordered, because a public id that encodes a creation
    time hands an attacker a way to enumerate and date other records from a
    single leaked link.
    """
    return uuid.uuid4()


def _decode_with(token: str, key: str, *, expected_type: str) -> dict[str, Any]:
    """Verify `token` against a single key and return its claims.

    Separated from `decode_token` so that the key-walking loop above owns the
    decision about *which* failure is retryable, and this function only has to
    worry about a token that was signed by the key it was handed.
    """
    try:
        claims = jwt.decode(token, key, algorithms=[get_settings().jwt_algorithm])
    except jwt.ExpiredSignatureError:
        # Re-raised rather than converted. PyJWT raises this only after the
        # signature has already been verified, so it is the one failure that
        # proves the token is genuine and merely old -- which is the difference
        # between "sign in again" and "something is wrong with your session",
        # and worth the caller being able to tell.
        raise
    except jwt.InvalidSignatureError:
        # Also re-raised, for a different reason: it is the only failure the
        # caller in `decode_token` is allowed to treat as "try the next key".
        # Converting it here would turn "wrong key" into a hard failure and make
        # a key set pointless, since the first key tried would always decide.
        raise
    except jwt.PyJWTError as exc:
        raise AuthenticationProblem("Your session is not valid.") from exc

    if claims.get("type") != expected_type:
        raise AuthenticationProblem("Your session is not valid.")

    return claims


def _encode(
    *,
    subject: uuid.UUID,
    token_type: str,
    ttl: timedelta,
    now: datetime,
    claims: dict[str, Any],
) -> str:
    settings = get_settings()
    payload = {
        "sub": str(subject),
        "type": token_type,
        "iat": int(now.timestamp()),
        "exp": int((now + ttl).timestamp()),
        **claims,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)
