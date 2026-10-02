"""Password hashing, token minting, opaque-token hashing, and identifiers.

Every test here corresponds to a numbered decision in the security register in
`docs/architecture.md`. The mapping is in each test's name, because a security
decision with no test enforcing it is an intention, not a decision.
"""

import asyncio
import os
import re
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from unittest.mock import patch

import jwt
import pytest
from jwt import ExpiredSignatureError

from app.core import security
from app.core.config import get_settings
from app.core.exceptions import AuthenticationProblem
from app.core.security import (
    burn_password_verification_async,
    hash_password_async,
    verify_password_async,
)

_A_PASSWORD = "correct horse battery staple"


def _expired_token(*, key: str | None = None) -> str:
    return jwt.encode(
        {
            "sub": str(uuid.uuid4()),
            "type": "access",
            "exp": int((datetime.now(UTC) - timedelta(hours=1)).timestamp()),
        },
        key or get_settings().jwt_secret,
        algorithm="HS256",
    )


# --- S1: Argon2id at the OWASP floor ----------------------------------------


def test_s1_password_is_hashed_with_argon2id() -> None:
    stored = security.hash_password(_A_PASSWORD)

    assert stored.startswith("$argon2id$")


def test_s1_argon2_parameters_are_recorded_in_the_hash() -> None:
    """The PHC string has to carry its own parameters.

    That is what makes S2 possible: a hash from an older, weaker configuration is
    self-describing, so it can be recognised and upgraded without a migration
    and without a table of what changed when.
    """
    stored = security.hash_password(_A_PASSWORD)

    assert re.search(r"\$m=(\d+),t=(\d+),p=(\d+)\$", stored)


def test_s1_argon2_parameters_are_never_below_the_owasp_floor() -> None:
    """Guards the floor itself, not just the current setting.

    A settings change that lowered the floor would be a silent downgrade, and
    nothing else in the suite would notice.
    """
    settings = get_settings()

    assert settings.password_hash_memory_kib >= 19_456
    assert settings.password_hash_time_cost >= 2
    assert settings.password_hash_parallelism >= 1


def test_s1_the_stored_hash_fits_the_password_hash_column() -> None:
    """`users.password_hash` is `String(255)`; a longer encoding would truncate.

    Truncation is silent in every database, and a truncated hash is an
    unverifiable one -- which locks the account out rather than weakening it,
    so it is a availability bug rather than a security one, and just as
    unacceptable.
    """
    stored = security.hash_password(_A_PASSWORD)

    assert len(stored) <= 255


# --- S2: rehash on successful verification -----------------------------------


def test_s2_a_hash_at_current_parameters_needs_no_rehash() -> None:
    assert not security.password_needs_rehash(security.hash_password(_A_PASSWORD))


def test_s2_a_hash_at_weaker_parameters_is_flagged_for_rehash() -> None:
    """The mechanism that makes raising the floor survivable.

    A hash made under weaker settings still verifies -- the stored parameters are
    honoured, so no one is locked out -- but it reports that it should be
    replaced, and the service rewrites the row after a successful sign-in.
    """
    weak = _hash_with(memory_cost=8_192, time_cost=1)

    assert security.password_needs_rehash(weak) is True


def test_s2_a_weak_hash_still_verifies_before_being_upgraded() -> None:
    weak = _hash_with(memory_cost=8_192, time_cost=1)

    assert security.verify_password(_A_PASSWORD, weak)


def test_s2_a_retired_format_is_flagged_for_rehash() -> None:
    assert security.password_needs_rehash("pbkdf2_sha256$600000$aabb$ccdd") is True


def test_s2_an_unreadable_hash_is_flagged_for_rehash() -> None:
    """Cannot be compared, so assume it is weak.

    Safe because rehash only ever happens after a *successful* verification,
    and a hash this function cannot read cannot pass one.
    """
    assert security.password_needs_rehash("not-a-hash") is True


# --- S3 / S4 live in app.core.password_policy, tested in test_password_policy ---


# --- Generic hashing behaviour ----------------------------------------------


def test_hash_password_never_stores_the_password() -> None:
    assert _A_PASSWORD not in security.hash_password(_A_PASSWORD)


def test_hash_password_salts_so_equal_passwords_differ() -> None:
    assert security.hash_password("same password") != security.hash_password(
        "same password"
    )


def test_verify_password_accepts_the_original_password() -> None:
    stored = security.hash_password(_A_PASSWORD)

    assert security.verify_password(_A_PASSWORD, stored)


def test_verify_password_rejects_a_wrong_password() -> None:
    stored = security.hash_password(_A_PASSWORD)

    assert not security.verify_password("wrong password", stored)


@pytest.mark.parametrize(
    "malformed",
    ["", "notahash", "pbkdf2_sha256$only-three-parts", "md5$1$aa$bb", "$argon2id$"],
)
def test_verify_password_rejects_a_malformed_hash(malformed: str) -> None:
    """A corrupt stored value must fail closed, not raise.

    Returning False rather than propagating matters: a row with a corrupt hash
    should deny access, not take the service down.
    """
    assert not security.verify_password("anything", malformed)


def test_verify_password_refuses_the_retired_pbkdf2_format() -> None:
    """No compatibility branch, on purpose.

    The users table is empty, so a hash in the old format cannot exist. Keeping
    a reader for it would be a timing oracle -- the two formats cost very
    different amounts of time to check, so it would tell an attacker which
    accounts predate a migration -- in exchange for recovering nothing.
    """
    retired = _legacy_pbkdf2_hash(_A_PASSWORD)

    assert security.verify_password(_A_PASSWORD, retired) is False


# --- S5: the subject is a public id ------------------------------------------


def test_s5_access_token_subject_is_the_public_id_it_was_given() -> None:
    """`create_token_pair` is handed a public id and puts it in `sub`.

    A JWT payload is base64, not encrypted. Whatever goes in `sub` is readable
    by the client on every request, forever, so the only identifier this project
    treats as publishable is the one that belongs there.
    """
    public_id = security.new_public_id()

    claims = security.decode_token(
        security.create_token_pair(subject=public_id).access_token,
        expected_type="access",
    )

    assert claims["sub"] == str(public_id)


# --- S6: no authorization data in a bearer token ----------------------------


def test_s6_an_access_token_carries_no_roles() -> None:
    """Roles are read per request, so revocation is immediate.

    A tutor suspended after a token was minted must lose tutor privileges on
    their next request. If roles were a claim, they would keep them until the
    token expired -- up to `access_token_ttl` minutes of a suspended tutor
    still matching. That is the core safety mechanism of the product, so the
    window is not acceptable.
    """
    claims = security.decode_token(
        security.create_token_pair(subject=security.new_public_id()).access_token,
        expected_type="access",
    )

    assert "roles" not in claims
    assert set(claims) == {"sub", "type", "iat", "exp", "jti"}


def test_s6_an_access_token_has_an_individual_identifier() -> None:
    """`jti` on the access token, so one token can be named and denied.

    The plumbing for an access-token deny-list. It costs one claim and needs no
    code today, and having it in the token from the start means adding the
    deny-list later does not require reissuing anything.
    """
    claims = security.decode_token(
        security.create_token_pair(subject=security.new_public_id()).access_token,
        expected_type="access",
    )

    assert uuid.UUID(claims["jti"])


# --- S8: zero-downtime signing key rotation ----------------------------------


def test_s8_a_token_signed_by_a_retired_key_still_verifies() -> None:
    """The point of keeping a key set rather than a single key.

    Rotation is the only time a signing key changes, and with a single key it
    means every student on the network is signed out at the same moment.
    """
    retired = _ROTATION_KEYS[0]

    with _signing_key(_ROTATION_KEYS[1]), _retired_keys([retired]):
        claims = security.decode_token(
            _token_signed_with(retired), expected_type="access"
        )

    assert claims["type"] == "access"


def test_s8_a_token_signed_by_an_unknown_key_is_rejected() -> None:
    with _signing_key(_ROTATION_KEYS[1]), _retired_keys([_ROTATION_KEYS[0]]):
        forged = _token_signed_with("a-key-this-service-has-never-held-at-all")

        with pytest.raises(AuthenticationProblem):
            security.decode_token(forged, expected_type="access")


def test_s8_the_primary_key_is_always_first_in_the_verification_set() -> None:
    settings = get_settings()

    assert settings.jwt_verification_secrets[0] == settings.jwt_secret


def test_s8_a_retired_key_cannot_sign() -> None:
    """Retired means verify-only.

    Once a key is in the retired list, anything newly minted is signed by the new
    primary, so a freshly issued token does not verify under the old key. That is
    what makes the old key safe to leave in the verification set: it can check a
    token that is already in the wild, and it cannot produce a new one.
    """
    retired = _ROTATION_KEYS[0]

    with _signing_key(_ROTATION_KEYS[1]), _retired_keys([retired]):
        fresh = security.create_token_pair(subject=security.new_public_id())

        assert _verifies_under(fresh.access_token, retired) is False
        assert _verifies_under(fresh.access_token, _ROTATION_KEYS[1]) is True


# --- S9: opaque token hashing ------------------------------------------------


def test_s9_an_opaque_token_is_long_enough_to_be_unguessable() -> None:
    token = security.generate_opaque_token()

    assert len(token) >= 43
    assert re.fullmatch(r"[A-Za-z0-9_-]+", token)


def test_s9_opaque_tokens_do_not_repeat() -> None:
    assert security.generate_opaque_token() != security.generate_opaque_token()


def test_s9_a_token_hash_fits_the_token_hash_column() -> None:
    """`RefreshToken.token_hash` is `String(128)`; 64 hex characters fits."""
    assert len(security.hash_opaque_token(security.generate_opaque_token())) <= 128


def test_s9_a_token_hash_is_deterministic_so_a_lookup_can_find_it() -> None:
    """Unlike a password, the presented token is re-presented verbatim.

    A salted hash would make the stored value useless for locating the row, so
    the pepper is what provides the protection here: a stolen database yields
    hashes that cannot be checked without also stealing the application.
    """
    token = security.generate_opaque_token()

    assert security.hash_opaque_token(token) == security.hash_opaque_token(token)


def test_s9_a_token_hash_never_contains_the_token() -> None:
    token = security.generate_opaque_token()

    assert token not in security.hash_opaque_token(token)


def test_s9_verify_opaque_token_accepts_only_the_right_token() -> None:
    token = security.generate_opaque_token()
    stored = security.hash_opaque_token(token)

    assert security.verify_opaque_token(token, stored)
    assert not security.verify_opaque_token("some-other-token", stored)


def test_s9_a_malformed_stored_hash_is_rejected_without_comparing() -> None:
    assert not security.verify_opaque_token("anything", "short")


def test_s9_rotating_the_pepper_invalidates_stored_token_hashes() -> None:
    """The documented cost of rotating the pepper, asserted so it stays known.

    Every session signs out, because no stored hash was made under the new
    pepper. That is why the pepper is a separate setting from the signing key:
    the two rotate for different reasons and at different times.
    """
    token = security.generate_opaque_token()
    before = security.hash_opaque_token(token)

    with _pepper("a-different-pepper-value-entirely-0123456789"):
        assert security.hash_opaque_token(token) != before


# --- Token typing and expiry -------------------------------------------------


def test_create_token_pair_mints_distinct_access_and_refresh_tokens() -> None:
    pair = security.create_token_pair(subject=security.new_public_id())

    assert pair.access_token != pair.refresh_token
    assert isinstance(pair.refresh_token_id, uuid.UUID)


def test_decode_token_rejects_a_refresh_token_used_as_an_access_token() -> None:
    """Type confusion is the whole point of the `type` claim.

    Without it, the long-lived refresh token would work as an access token and
    rotation would be pointless.
    """
    pair = security.create_token_pair(subject=security.new_public_id())

    with pytest.raises(AuthenticationProblem):
        security.decode_token(pair.refresh_token, expected_type="access")


def test_refresh_token_carries_the_handle_used_to_rotate_it() -> None:
    pair = security.create_token_pair(subject=security.new_public_id())

    claims = security.decode_token(pair.refresh_token, expected_type="refresh")

    assert claims["jti"] == str(pair.refresh_token_id)


def test_decode_token_rejects_a_token_signed_with_another_key() -> None:
    with pytest.raises(AuthenticationProblem):
        security.decode_token(
            _token_signed_with("a-completely-different-signing-key-value"),
            expected_type="access",
        )


def test_decode_token_rejects_an_expired_token() -> None:
    expired = _expired_token()

    with pytest.raises(ExpiredSignatureError):
        jwt.decode(expired, get_settings().jwt_secret, algorithms=["HS256"])

    with pytest.raises(AuthenticationProblem):
        security.decode_token(expired, expected_type="access")


def test_an_expired_token_is_reported_distinctly_from_a_forged_one() -> None:
    """A signed-in user whose session aged out should be told so.

    Everything else is "not valid". Telling an expired user their token is
    forged would be a small lie that hides the real reason they are back at the
    sign-in screen, so this one case is allowed to differ. It leaks nothing,
    because a caller cannot obtain an expired-but-valid signature without
    already holding a real token.
    """
    with pytest.raises(AuthenticationProblem, match="session has ended"):
        security.decode_token(_expired_token(), expected_type="access")

    with pytest.raises(AuthenticationProblem, match="not valid"):
        security.decode_token(
            _token_signed_with("an-entirely-unknown-signing-key-value"),
            expected_type="access",
        )


# --- Identifiers -------------------------------------------------------------


def test_new_uuid7_is_time_ordered() -> None:
    """Time-ordered keys keep inserts at the end of the primary-key index."""
    generated = [security.new_uuid7() for _ in range(50)]

    assert generated == sorted(generated)


def test_new_public_id_is_version_4() -> None:
    """A public id must not encode its creation time.

    A time-ordered public id would let a single leaked link be used to date and
    enumerate other records.
    """
    assert security.new_public_id().version == 4


# --- Helpers -----------------------------------------------------------------

#: Two distinct 32-character keys, so a test can move from one to the other and
#: have the previous one behave like a genuinely retired key.
_ROTATION_KEYS = (
    "rotation-key-aaaaaaaaaaaaaaaaaaaa",
    "rotation-key-bbbbbbbbbbbbbbbbbbbb",
)


def _token_signed_with(key: str) -> str:
    return jwt.encode(
        {
            "sub": str(uuid.uuid4()),
            "type": "access",
            "iat": int(datetime.now(UTC).timestamp()),
            "exp": int((datetime.now(UTC) + timedelta(hours=1)).timestamp()),
            "jti": str(uuid.uuid4()),
        },
        key,
        algorithm="HS256",
    )


def _verifies_under(token: str, key: str) -> bool:
    """Whether `token` carries a valid signature made with `key`."""
    try:
        jwt.decode(token, key, algorithms=["HS256"])
    except jwt.PyJWTError:
        return False
    return True


def _hash_with(*, memory_cost: int, time_cost: int) -> str:
    """A hash built with non-current parameters, for the rehash tests."""
    from argon2 import PasswordHasher

    return PasswordHasher(
        time_cost=time_cost, memory_cost=memory_cost, parallelism=1
    ).hash(_A_PASSWORD)


def _legacy_pbkdf2_hash(password: str) -> str:
    """Reproduce the retired storage format, so the refusal can be tested."""
    import hashlib

    salt = b"\x01" * 16
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 1_000)
    return f"pbkdf2_sha256$1000${salt.hex()}${digest.hex()}"


@contextmanager
def _settings(**overrides: str):
    """Run a block with different settings, then restore them.

    Settings are cached with `lru_cache`, so the cache has to be cleared both on
    the way in and on the way out. Without the second clear, a test that rotates
    a key would leave that key in place for everything that runs after it.
    """
    get_settings.cache_clear()
    with patch.dict(os.environ, overrides):
        get_settings.cache_clear()
        try:
            yield
        finally:
            get_settings.cache_clear()


def _signing_key(value: str):
    return _settings(JWT_SECRET=value, JWT_PREVIOUS_SECRETS="")


def _retired_keys(keys: list[str]):
    return _settings(JWT_PREVIOUS_SECRETS=",".join(keys))


def _pepper(value: str):
    return _settings(TOKEN_PEPPER=value)


# ---------------------------------------------------------------------------
# The awaitable forms exist so that Argon2 does not run on the event loop.
#
# These tests are about *where* the work happens, not what it returns -- the
# return values are covered by the sync tests above. A test that only asserted
# "hash_password_async('x') == hash_password('x')" would pass just as happily
# against an implementation that blocks the loop, which is the thing that
# actually matters here.
# ---------------------------------------------------------------------------


async def test_hashing_runs_on_a_thread_other_than_the_event_loop(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    caller_thread = threading.get_ident()
    where: list[int] = []

    def _spy(password: str) -> str:
        where.append(threading.get_ident())
        return "$argon2id$fake"

    monkeypatch.setattr("app.core.security.hash_password", _spy)

    await hash_password_async("a password")

    assert where and where[0] != caller_thread


async def test_verifying_runs_on_a_thread_other_than_the_event_loop(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    caller_thread = threading.get_ident()
    where: list[int] = []

    def _spy(password: str, stored: str) -> bool:
        where.append(threading.get_ident())
        return True

    monkeypatch.setattr("app.core.security.verify_password", _spy)

    assert await verify_password_async("a password", "$argon2id$fake") is True
    assert where and where[0] != caller_thread


async def test_the_burn_on_an_unknown_address_also_leaves_the_loop_free(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The branch that runs for *unregistered* addresses must not block either.

    This is the one that matters most. It fires when no account matched, so it
    is reachable by anyone who knows an address and nothing else -- the decoy
    burn exists specifically to stop the response time telling a prober which
    addresses are registered, and it cannot do that job while it is also
    freezing the event loop for everyone else.
    """
    caller_thread = threading.get_ident()
    where: list[int] = []

    monkeypatch.setattr(
        "app.core.security.burn_password_verification",
        lambda: where.append(threading.get_ident()),
    )

    await burn_password_verification_async()

    assert where and where[0] != caller_thread


async def test_the_event_loop_keeps_serving_requests_during_a_hash() -> None:
    """A coroutine running alongside a real hash must actually get to run.

    The thread assertions above pin the mechanism down; this one is the
    behaviour that matters. A blocking implementation leaves the counter at
    zero for the whole duration of the hash, because the loop never gets
    scheduled. `asyncio.sleep(0)` alone would not prove it either -- it yields
    once -- so the task spins until the hash finishes, and any progress at all
    is evidence the loop stayed free.
    """
    ticks = 0

    async def _spin() -> None:
        nonlocal ticks
        while True:
            ticks += 1
            await asyncio.sleep(0)

    spinner = asyncio.create_task(_spin())
    await asyncio.sleep(0)  # let the spinner actually start before hashing

    # Measured across the hash rather than from zero. The yield above lets the
    # spinner tick once on its own, and counting that would make this pass
    # against the very implementation it is meant to catch.
    before = ticks
    try:
        await hash_password_async("a password worth hashing")
    finally:
        spinner.cancel()

    assert ticks > before


async def test_concurrent_hashes_are_capped_rather_than_all_held_at_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The cap is a memory ceiling, so it has to be observable, not merely set.

    At 19 MiB a concurrent hash, a pool that grows with the number of waiting
    requests does not rate-limit anything -- it just decides the order in which
    the out-of-memory kill arrives. Four workers must stay four workers however
    many sign-ins are queued behind them.
    """
    from app.core import security as security_module

    # One pool, created here. Returning a fresh executor from the patched
    # callable would hand every waiting request its own pair of workers and
    # measure nothing.
    pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="argon2-test")
    monkeypatch.setattr(security_module, "_argon2_executor", lambda: pool)
    concurrent = 0
    peak = 0
    lock = threading.Lock()

    def _counting_hash(_password: str) -> str:
        nonlocal concurrent, peak
        with lock:
            concurrent += 1
            peak = max(peak, concurrent)
        time.sleep(0.02)
        with lock:
            concurrent -= 1
        return "$argon2id$fake"

    monkeypatch.setattr("app.core.security.hash_password", _counting_hash)

    try:
        await asyncio.gather(*(hash_password_async("a password") for _ in range(12)))
    finally:
        pool.shutdown(wait=True)

    assert peak <= 2


async def test_the_pool_size_follows_the_setting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The ceiling must be configurable, because it is an instance-size decision.

    The calculation is `password_hash_max_concurrency * password_hash_memory_kib`
    against the container's memory limit. A fixed number is right for one
    instance and wrong for every other.
    """
    from app.core import security as security_module

    monkeypatch.setenv("PASSWORD_HASH_MAX_CONCURRENCY", "7")
    # Both caches matter: the settings singleton may already hold values from an
    # earlier test, and the pool is memoised on the first call, so a cleared
    # settings cache alone still hands back the pool built at the old size.
    get_settings.cache_clear()
    security_module._argon2_executor.cache_clear()

    executor = security_module._argon2_executor()
    try:
        assert executor._max_workers == 7
    finally:
        executor.shutdown(wait=True)
        security_module._argon2_executor.cache_clear()
        get_settings.cache_clear()
