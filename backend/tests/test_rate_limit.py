"""Rate limiting on sign-in and sign-up.

The properties asserted here are the ones that make the limiter worth having,
and each of them is a way a limiter written the obvious way fails:

- The account ceiling exists and is per account.
- The address ceiling exists, and is what actually bounds a spraying attack --
  a per-account limit alone does not slow it down, because every account it
  touches starts with zero failures against it.
- Neither is defeated by sending attempts in parallel. This is the one that
  matters most and the one that is easiest to get wrong: an increment written as
  "read the row, add one, write it back" loses counts under concurrency, so an
  attacker willing to batch gets `max_attempts` tries per batch, forever.
- A success clears the account counter but not the address one.
- The proxy-header rules hold, because both misconfigurations are severe and in
  opposite directions.
"""

import asyncio
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.core.config import get_settings
from app.models.rate_limit import RateLimitCounter
from app.schemas.user import RegisterRequest
from app.services import auth_service, rate_limit
from app.services.auth_service import ConflictProblem

LOGIN_URL = "/v1/auth/login"
REGISTER_URL = "/v1/auth/register"

PASSWORD = "correct horse battery staple"
WRONG = "a different but equally long password"

UNKNOWN_ACCOUNT = "no.such.person@peerpass.co.ug"


def _email(name: str) -> str:
    return f"{name}@peerpass.co.ug"


async def _register(env, email: str, password: str = PASSWORD, client=None):
    client = client or env.client
    return await client.post(REGISTER_URL, json={"email": email, "password": password})


async def _sign_in(env, email: str, password: str = WRONG, client=None):
    client = client or env.client
    return await client.post(LOGIN_URL, json={"email": email, "password": password})


async def _counter(env, scope: str, key: str) -> RateLimitCounter | None:
    async with env.session() as session:
        result = await session.execute(
            select(RateLimitCounter).where(
                RateLimitCounter.scope == scope, RateLimitCounter.key == key
            )
        )
        return result.scalar_one_or_none()


# --- the account ceiling ---------------------------------------------------


async def test_five_wrong_passwords_lock_an_account_out(committed_env) -> None:
    """The account ceiling, and it bites on the request *after* the last try.

    Each of the five is evaluated and reports 401: the student is entitled to the
    tries they were given. The last of them arms the lock, so someone who
    mistypes five times is refused the sixth rather than the fifth.
    """
    settings = get_settings()
    email = _email("lockout.student")
    assert (await _register(committed_env, email)).status_code == 201

    for attempt in range(1, settings.auth_login_max_attempts + 1):
        response = await _sign_in(committed_env, email)
        assert response.status_code == 401, (attempt, response.text)

    assert (await _sign_in(committed_env, email)).status_code == 429


async def test_a_locked_account_is_refused_even_with_the_right_password(
    committed_env,
) -> None:
    """A lockout that only rejects wrong guesses is not a lockout."""
    email = _email("correct.but.locked")
    await _register(committed_env, email)
    for _ in range(get_settings().auth_login_max_attempts):
        await _sign_in(committed_env, email)

    response = await _sign_in(committed_env, email, PASSWORD)
    assert response.status_code == 429, response.text


async def test_the_lockout_lifts_when_the_cooldown_is_up(committed_env) -> None:
    """A lock with no expiry is an outage, not a throttle."""
    email = _email("impatient.student")
    await _register(committed_env, email)
    for _ in range(get_settings().auth_login_max_attempts):
        await _sign_in(committed_env, email)

    # Age the lock instead of sleeping through it.
    counter = await _counter(committed_env, rate_limit.SCOPE_LOGIN_ACCOUNT, email)
    counter.locked_until = datetime.now(UTC) - timedelta(seconds=1)
    async with committed_env.session() as session:
        await session.merge(counter)
        await session.commit()

    response = await _sign_in(committed_env, email, PASSWORD)
    assert response.status_code == 200, response.text


async def test_a_lockout_keyed_on_the_email_ignores_casing(committed_env) -> None:
    """The key is the normalised address, so holding shift is not a way out.

    Sign-in normalises before looking the user up, so `Student@` and `student@`
    are one account. The counter has to agree, or the ceiling would fall off
    whenever the attacker felt like capitalising.
    """
    email = _email("casing.student")
    await _register(committed_env, email)
    for _ in range(get_settings().auth_login_max_attempts):
        await _sign_in(committed_env, email.upper())

    assert (await _sign_in(committed_env, email, PASSWORD)).status_code == 429


# --- the address ceiling ---------------------------------------------------


async def test_one_address_spraying_many_accounts_runs_out(committed_env) -> None:
    """The ceiling that actually bounds a spraying attack.

    Every account below has *zero* failures against it, so a per-account limit
    does nothing here. Without the address counter this loop would run to the end
    of the list and never be refused.
    """
    settings = get_settings()
    for index in range(settings.auth_login_ip_max_attempts + 5):
        response = await _sign_in(committed_env, _email(f"victim{index}"))
        if response.status_code == 429:
            assert index >= settings.auth_login_ip_max_attempts, index
            return
    pytest.fail("the address was never throttled")


async def test_a_throttled_address_is_refused_even_with_a_good_password(
    committed_env,
) -> None:
    email = _email("good.password")
    await _register(committed_env, email)
    for index in range(get_settings().auth_login_ip_max_attempts):
        await _sign_in(committed_env, _email(f"other{index}"))

    response = await _sign_in(committed_env, email, PASSWORD)
    assert response.status_code == 429, response.text


async def test_a_throttled_address_does_not_throttle_the_next_one(
    committed_env,
) -> None:
    """The address counter is per address, so one attacker cannot lock out a campus.

    A share of a NAT means many honest students arrive from one address. Were
    this counter global, one determined attacker exhausting it would lock out
    everyone behind that address, which is a denial of service handed out for
    free.
    """
    settings = get_settings()
    email = _email("next.door")
    await _register(committed_env, email)

    for index in range(settings.auth_login_ip_max_attempts):
        await _sign_in(committed_env, _email(f"spray{index}"))
    assert (await _sign_in(committed_env, _email("another"))).status_code == 429

    elsewhere = committed_env.from_address("203.0.113.77")
    response = await _sign_in(committed_env, email, PASSWORD, client=elsewhere)
    assert response.status_code == 200, response.text


# --- concurrency -----------------------------------------------------------


async def test_parallel_failures_are_all_counted(
    committed_env, client_address, monkeypatch
) -> None:
    """The increment is atomic, so batching does not buy extra attempts.

    This is the test the whole increment design exists for. Written as
    read-modify-write, twenty concurrent failures all read `attempts = 0` and
    all write `1`: the counter ends at 1, the ceiling is never reached, and the
    limiter is decoration.

    Both ceilings are raised above the batch size on purpose. Once a lock arms,
    later attempts are refused *without* being counted, and those correct
    refusals would otherwise mask the lost updates being looked for.

    The requests go out together on the fixture's own client, which hands every
    request a *separate* database session -- exactly the situation the bug
    needs, and why this cannot be tested through one shared session.
    """
    monkeypatch.setenv("AUTH_LOGIN_MAX_ATTEMPTS", "100")
    monkeypatch.setenv("AUTH_LOGIN_IP_MAX_ATTEMPTS", "1000")
    get_settings.cache_clear()
    try:
        email = _email("parallel.student")
        await _register(committed_env, email)

        attempts = 20
        responses = await asyncio.gather(
            *(
                committed_env.client.post(
                    LOGIN_URL, json={"email": email, "password": WRONG}
                )
                for _ in range(attempts)
            )
        )
        assert all(r.status_code == 401 for r in responses)

        account = await _counter(committed_env, rate_limit.SCOPE_LOGIN_ACCOUNT, email)
        by_address = await _counter(
            committed_env, rate_limit.SCOPE_LOGIN_IP, client_address
        )
        assert account.attempts == attempts, account.attempts
        assert by_address.attempts == attempts, by_address.attempts
    finally:
        get_settings.cache_clear()


async def test_parallel_failures_still_lock_the_account_out(committed_env) -> None:
    """The lock is armed by the same statement that increments, so arriving all
    at once cannot skip it."""
    settings = get_settings()
    email = _email("parallel.lock")
    await _register(committed_env, email)

    await asyncio.gather(
        *(
            committed_env.client.post(
                LOGIN_URL, json={"email": email, "password": WRONG}
            )
            for _ in range(settings.auth_login_max_attempts)
        )
    )

    response = await committed_env.client.post(
        LOGIN_URL, json={"email": email, "password": PASSWORD}
    )
    assert response.status_code == 429, response.text


# --- what a success clears, and what it must not ----------------------------


async def test_a_good_sign_in_forgets_the_student_s_mistakes(committed_env) -> None:
    """Otherwise a student who mistypes twice pays for it forever."""
    settings = get_settings()
    email = _email("forgetful.student")
    await _register(committed_env, email)

    for _ in range(settings.auth_login_max_attempts - 1):
        await _sign_in(committed_env, email)
    await _sign_in(committed_env, email, PASSWORD)

    await _sign_in(committed_env, email)
    assert (await _sign_in(committed_env, email, PASSWORD)).status_code == 200


async def test_a_good_sign_in_does_not_refill_the_address_budget(
    committed_env,
) -> None:
    """The reset that must *not* happen.

    An attacker holding one valid account would otherwise mint an unlimited
    attempt budget by signing in between runs, and the address ceiling would be
    no ceiling at all.
    """
    settings = get_settings()
    attacker = _email("attacker")
    await _register(committed_env, attacker)

    for index in range(settings.auth_login_ip_max_attempts):
        await _sign_in(committed_env, _email(f"guess{index}"))
        await _sign_in(committed_env, attacker, PASSWORD)

    assert (await _sign_in(committed_env, _email("one.more"))).status_code == 429


# --- the response ----------------------------------------------------------


async def test_a_throttled_response_carries_a_retry_after_header(committed_env) -> None:
    """A 429 whose only wait time is inside the JSON is not machine-readable.

    RFC 6585 asks for `Retry-After` as a header, and infrastructure in front of
    the API reads headers rather than parsing problem documents. The body field
    is kept too, because this project's own clients read that.
    """
    settings = get_settings()
    email = _email("header.student")
    await _register(committed_env, email)
    for _ in range(settings.auth_login_max_attempts):
        await _sign_in(committed_env, email)

    response = await _sign_in(committed_env, email, PASSWORD)
    assert response.status_code == 429
    retry_after = int(response.headers["Retry-After"])
    assert 0 < retry_after <= settings.auth_login_lockout_seconds
    assert retry_after == response.json()["errors"]["retry_after_seconds"]


async def test_a_wrong_password_still_says_nothing_about_why(committed_env) -> None:
    """Adding the limiter must not undo the enumeration defence.

    The body an unknown address gets must stay byte-identical to the one a wrong
    password gets. If the limiter began distinguishing them, the address ceiling
    would have become an enumeration oracle instead of a throttle.
    """
    unknown = await _sign_in(committed_env, UNKNOWN_ACCOUNT)
    email = _email("known.student")
    await _register(committed_env, email)
    wrong = await _sign_in(committed_env, email)

    assert unknown.status_code == wrong.status_code == 401
    assert unknown.json() == wrong.json()


async def test_a_throttled_address_says_nothing_about_which_accounts_it_knows(
    committed_env,
) -> None:
    """Once an address is throttled, every account looks the same from it.

    Were a throttled request to return 401 for an unknown address and 429 for a
    locked one, the address ceiling would hand out the list of which addresses
    have accounts -- the exact thing the decoy burn in `authenticate` exists to
    prevent.
    """
    settings = get_settings()
    email = _email("enumerable")
    await _register(committed_env, email)
    for index in range(settings.auth_login_ip_max_attempts):
        await _sign_in(committed_env, _email(f"guess{index}"))

    unknown = await _sign_in(committed_env, UNKNOWN_ACCOUNT)
    known = await _sign_in(committed_env, email)

    assert unknown.status_code == known.status_code == 429
    assert unknown.json()["code"] == known.json()["code"]


# --- registration ----------------------------------------------------------


async def test_registration_is_throttled_per_address(
    committed_env, monkeypatch
) -> None:
    """Each accepted sign-up costs a full Argon2 hash, so the count is a CPU
    ceiling as much as a request ceiling.

    The ceiling is lowered for the test because the configured default is
    deliberately high enough that a test should not perform fifty hashes.
    """
    monkeypatch.setenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "3")
    get_settings.cache_clear()
    try:
        statuses = [
            (await _register(committed_env, _email(f"newcomer{i}"))).status_code
            for i in range(5)
        ]
    finally:
        get_settings.cache_clear()

    assert statuses[:3] == [201, 201, 201], statuses
    assert statuses[3:] == [429, 429], statuses


async def test_a_throttled_address_cannot_register_but_another_can(
    committed_env, monkeypatch
) -> None:
    """Registration counts per address, like sign-in.

    Start of term is genuinely bursty and a campus sits behind one NAT, so a
    ceiling that stops an attacker must not be one that stops an intake.
    """
    monkeypatch.setenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "2")
    get_settings.cache_clear()
    try:
        for index in range(2):
            assert (
                await _register(committed_env, _email(f"term{index}"))
            ).status_code == 201

        blocked = await _register(committed_env, _email("over.the.line"))
        assert blocked.status_code == 429, blocked.text

        elsewhere = committed_env.from_address("203.0.113.88")
        response = await _register(
            committed_env, _email("other.network"), client=elsewhere
        )
        assert response.status_code == 201, response.text
    finally:
        get_settings.cache_clear()


# --- probes for addresses that already have accounts -----------------------


async def test_probing_existing_accounts_is_throttled_like_real_signups(
    committed_env, monkeypatch
) -> None:
    """The duplicate path costs a full Argon2 hash, so it is charged for one.

    This is the enumeration oracle. Every probe below returns 409, which tells
    the caller the address has an account, and each one paid for a hash on the
    way. Charging only successful sign-ups — the first version of this — left
    the endpoint with an unlimited hashing budget for anyone willing to send
    addresses that already exist, and a strictly better oracle than sign-in,
    where a wrong password costs the same hash and *is* counted.
    """
    monkeypatch.setenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "4")
    get_settings.cache_clear()
    try:
        victim = _email("already.enrolled")
        assert (await _register(committed_env, victim)).status_code == 201

        statuses = []
        for _ in range(6):
            response = await _register(committed_env, victim)
            statuses.append(response.status_code)
            if response.status_code == 429:
                break

        # The first probe is still answered in full: the budget was spent by the
        # sign-up itself plus the probes after it, not by the first probe.
        assert statuses[0] == 409, statuses
        assert 429 in statuses, statuses
    finally:
        get_settings.cache_clear()


async def test_a_student_who_retries_their_own_address_is_still_told_to_sign_in(
    committed_env, monkeypatch
) -> None:
    """Throttling must not swallow the message the student needs.

    The budget is small here on purpose. A duplicate still answers 409 with the
    plain-language reason until the budget is spent; it does not start returning
    429 the moment an address exists, which would be useless to the honest
    student it is aimed at.
    """
    monkeypatch.setenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "5")
    get_settings.cache_clear()
    try:
        email = _email("forgetful.registrant")
        assert (await _register(committed_env, email)).status_code == 201

        response = await _register(committed_env, email)
        assert response.status_code == 409, response.text
        assert response.json()["detail"] == (
            "An account already exists for that email address."
        )
    finally:
        get_settings.cache_clear()


async def test_a_rejected_password_is_not_charged(committed_env, monkeypatch) -> None:
    """A refusal that happens before the hash costs nothing, so it is not charged.

    Otherwise a student who fumbled a password policy would spend their sign-up
    budget on typos, having consumed no server CPU at all.

    The ceiling is set below the number of rejections on purpose. At the default
    these rejections could all be charged without exhausting anything, and the
    final sign-up would succeed either way — a test that passes whether or not
    the behaviour exists.
    """
    monkeypatch.setenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "5")
    get_settings.cache_clear()
    try:
        email = _email("weak.password")
        for _ in range(9):
            # Schema-valid but on the deny-list. A five-character password would
            # be rejected by the request schema before the service is reached,
            # which is a different rejection that never reaches the hash either.
            response = await _register(committed_env, email, password="Password1!")
            assert response.status_code == 422, response.text

        # The budget is untouched, so a real sign-up still works.
        assert (
            await _register(committed_env, email, password=PASSWORD)
        ).status_code == 201
    finally:
        get_settings.cache_clear()


async def test_the_lost_race_for_an_address_is_still_charged(
    committed_env, client_address, monkeypatch
) -> None:
    """The branch that two simultaneous sign-ups take is charged too.

    Two requests for one new address can both pass the duplicate pre-check, and
    the unique index then refuses one of them. That refusal has to be charged on
    the same terms as the pre-check refusal, or the winner's budget is a budget
    of one per pair.

    Reaching it needs a real interleaving, which a test cannot schedule. So the
    pre-check is stubbed out instead: it reports that the address is free while
    the account is already in the database, which is precisely the state the
    loser of a race observes. Stubbing the lookup is what makes this deterministic
    -- and stubbing it is safe here because it makes the *duplicate* case more
    likely, never less.
    """
    email = _email("lost-race")
    assert (await _register(committed_env, email, password=PASSWORD)).status_code == 201

    async def _pretend_the_address_is_free(*_args, **_kwargs):
        return None

    monkeypatch.setattr(
        auth_service, "load_user_by_email", _pretend_the_address_is_free
    )

    request = RegisterRequest(email=email, password=PASSWORD)
    async with committed_env.session() as session:
        with pytest.raises(ConflictProblem):
            await auth_service.register(session, request, client_address=client_address)

    counter = await _counter(
        committed_env, rate_limit.SCOPE_REGISTER_IP, client_address
    )
    assert counter is not None, (
        "the refusal down the IntegrityError branch cost nothing"
    )
    assert counter.attempts == 2, counter.attempts


async def test_probing_costs_a_hash_and_is_bounded_by_the_same_budget(
    committed_env, monkeypatch
) -> None:
    """Successes and duplicates draw on one budget, not two.

    An attacker alternates: create an account, then probe it, then create
    another. If only successes were counted they would get half the ceiling back
    per round.
    """
    monkeypatch.setenv("AUTH_REGISTER_IP_MAX_ATTEMPTS", "6")
    get_settings.cache_clear()
    try:
        statuses = []
        for index in range(8):
            statuses.append(
                (await _register(committed_env, _email(f"round{index}"))).status_code
            )
            statuses.append(
                (await _register(committed_env, _email(f"round{index}"))).status_code
            )
            if 429 in statuses:
                break

        assert statuses.count(201) + statuses.count(409) <= 6, statuses
        assert statuses[-1] == 429, statuses
    finally:
        get_settings.cache_clear()


# --- the client address ----------------------------------------------------


class _Peer:
    def __init__(self, host: str | None) -> None:
        self.host = host


class _Request:
    """The two things `client_ip` reads off a request."""

    def __init__(
        self, headers: dict[str, str] | None = None, host: str | None = "203.0.113.9"
    ):
        self.headers = headers or {}
        self.client = _Peer(host)


class TestClientAddress:
    def test_the_socket_address_is_used_when_no_proxy_is_declared(self):
        assert rate_limit.client_ip(_Request()) == "203.0.113.9"

    def test_a_forwarded_header_is_ignored_when_no_proxy_is_declared(self):
        """Trusting it unconditionally would let a caller choose their own
        bucket.

        Setting the header is one line of curl, and it would hand out a fresh
        rate-limit identity per request, which makes the address ceiling
        decorative.
        """
        request = _Request(headers={"x-forwarded-for": "1.2.3.4"})
        assert rate_limit.client_ip(request) == "203.0.113.9"

    @pytest.mark.parametrize(
        ("hops", "chain", "expected"),
        [
            ("1", "198.51.100.7", "198.51.100.7"),
            ("2", "198.51.100.7, 203.0.113.9", "198.51.100.7"),
            # An attacker who prepends a forged address lands it on the left, so
            # the rightmost entry is the one the closest trusted proxy wrote.
            ("2", "9.9.9.9, 198.51.100.7, 203.0.113.9", "198.51.100.7"),
            # A chain shorter than the declared hop count means the deployment is
            # misconfigured; guessing which entry to believe picks a forgeable one.
            ("3", "198.51.100.7", "203.0.113.9"),
        ],
    )
    def test_the_hop_count_decides_which_entry_is_believed(
        self, monkeypatch, hops, chain, expected
    ):
        monkeypatch.setenv("TRUSTED_PROXY_HOPS", hops)
        get_settings.cache_clear()
        try:
            request = _Request(headers={"x-forwarded-for": chain})
            assert rate_limit.client_ip(request) == expected
        finally:
            get_settings.cache_clear()

    def test_a_missing_peer_address_groups_requests_rather_than_failing(self):
        """A 500 because a socket had no address would be a self-inflicted
        outage. Such requests group under one key, which if anything is stricter
        than configured."""
        assert rate_limit.client_ip(_Request(host=None)) == rate_limit.UNKNOWN_CLIENT
