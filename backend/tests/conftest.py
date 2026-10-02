"""Shared backend test fixtures.

Settings are supplied through the environment before anything imports
`app.core.config`, because the settings object is constructed on first access
and cached. Clearing that cache is therefore not enough; the variables have to
be in place first.
"""

import os
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

import pytest

# Deliberately not prefixed with "test" or "changeme": Settings refuses a
# placeholder secret of any kind, and that guard should apply to the suite too.
_SUITE_JWT_SECRET = "peerpass-local-suite-signing-key-0123456789abcdef"
_SUITE_TOKEN_PEPPER = "peerpass-local-suite-token-pepper-0123456789abcdef"

os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")
os.environ.setdefault("JWT_SECRET", _SUITE_JWT_SECRET)
os.environ.setdefault("JWT_ALGORITHM", "HS256")
os.environ.setdefault("TOKEN_PEPPER", _SUITE_TOKEN_PEPPER)

from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy import event, text  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import get_settings  # noqa: E402
from app.core.database import Base  # noqa: E402


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    """Use the asyncio backend only.

    Declared explicitly so the intent is recorded: adding trio later is a
    deliberate decision, not an accident of whichever plugin is installed.
    """
    return "asyncio"


def _enable_sqlite_foreign_keys(dbapi_connection, _connection_record) -> None:
    """Turn on the foreign key enforcement SQLite leaves off by default."""
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


@pytest.fixture
def settings():
    """The settings built from the test environment."""
    return get_settings()


#: Points the whole suite at a real PostgreSQL instead of SQLite. Set it and the
#: same tests run against the database the service actually uses:
#:
#:     PEERPASS_TEST_DATABASE_URL=postgresql+psycopg://user@host/db pytest
#:
#: This is not a convenience. SQLite does not enforce `numeric(6,2)`, does not
#: name its constraints, and stores UUIDs as strings, so a green SQLite run is
#: not evidence the schema is valid on PostgreSQL. Running the same suite
#: against both is what caught a `standing` column that accepted any string,
#: which SQLite had happily reported as enforced.
TEST_DATABASE_URL = os.environ.get("PEERPASS_TEST_DATABASE_URL")


@pytest.fixture
async def db_engine():
    """An engine with the schema created, on SQLite unless overridden.

    SQLite is the default because the domain tests must run in CI with no
    database service.
    """
    if TEST_DATABASE_URL:
        engine = create_async_engine(TEST_DATABASE_URL)
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.drop_all)
            await connection.run_sync(Base.metadata.create_all)
        yield engine
        await engine.dispose()
        return

    engine = create_async_engine(
        "sqlite+aiosqlite:///:memory:",
        # SQLite enforces no foreign keys unless asked per connection. Without
        # this the ON DELETE CASCADE clauses are inert and every cascade test
        # passes without deleting anything.
        connect_args={"check_same_thread": False},
    )
    event.listen(engine.sync_engine, "connect", _enable_sqlite_foreign_keys)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()


@pytest.fixture
async def db_session(db_engine) -> AsyncIterator[AsyncSession]:
    """A session bound to the in-memory database."""
    factory = async_sessionmaker(
        bind=db_engine, class_=AsyncSession, expire_on_commit=False
    )
    async with factory() as session:
        yield session


@dataclass
class CommittedEnv:
    """A client whose requests each get their own session, plus a way in.

    `client` is the HTTP client. `session()` opens a session on the *same*
    engine, for the cases where a test has to arrange state the API cannot
    produce on its own -- granting the first admin, say. Anything written that
    way must be committed by the test, because a rollback is what this fixture
    exists to expose.
    """

    client: AsyncClient
    _factory: async_sessionmaker[AsyncSession]

    @asynccontextmanager
    async def session(self) -> AsyncIterator[AsyncSession]:
        async with self._factory() as session:
            yield session


@pytest.fixture
async def committed_env(tmp_path) -> AsyncIterator[CommittedEnv]:
    """A client where every request gets its own database session.

    The `client` fixture hands every request the *same* `db_session`. That is a
    deliberate convenience for tests that stage rows and then read them back, but
    it has a sharp edge: a service that adds rows and flushes without committing
    still appears to work, because the flush stays visible inside that shared
    session's open transaction and the next request is handed the same session.

    Production has no such session. `get_db` opens one per request and closes it
    at the end, which rolls back anything uncommitted. A suite that only ever
    exercises `client` therefore cannot tell the difference between a write that
    is persisted and one that only ever existed inside a transaction -- and a
    whole product surface can be green against rows no real request would leave
    behind. That is not hypothetical; see `tests/test_persistence.py`.

    This fixture removes the difference. It overrides `get_db` to build a fresh
    session per request, exactly as production does, so anything not committed by
    the time the request ends is gone.

    It follows `PEERPASS_TEST_DATABASE_URL` rather than always using SQLite. That
    matters because these are the tests that assert the suite's own blind spot is
    gone, and running them only against SQLite would mean the blind spot could
    still hide anything where SQLite and PostgreSQL disagree.

    Isolation is a fresh temporary file database, or a fresh schema on PostgreSQL.
    Not the shared test database: this fixture needs its own, because a test that
    used both would have one fixture's `drop_all` destroy the other's rows.

    Use it for any test that creates a row over HTTP and then reads it back over
    HTTP. Use `client` when the test is about a single response body, or when it
    stages its own rows directly and needs them visible without committing.
    """
    from app.core.database import get_db
    from app.main import create_app

    if TEST_DATABASE_URL:
        schema = f"committed_{uuid.uuid4().hex[:12]}"
        engine = create_async_engine(TEST_DATABASE_URL)
        # A per-test schema rather than a per-test database: `CREATE DATABASE`
        # cannot run inside a transaction and is far too slow to do once per
        # test. `search_path` confines every statement this engine issues.
        async with engine.begin() as connection:
            await connection.execute(text(f'CREATE SCHEMA "{schema}"'))
            await connection.execute(text(f'SET search_path TO "{schema}"'))
            await connection.run_sync(Base.metadata.create_all)
        teardown_schema = schema
    else:
        # On disk rather than `:memory:`. Separate connections to an in-memory
        # SQLite are separate databases, so per-request sessions would each open
        # a fresh, empty one and every test would fail for the wrong reason.
        engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'committed.db'}")
        event.listen(engine.sync_engine, "connect", _enable_sqlite_foreign_keys)
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        teardown_schema = None

    # `search_path` is per-connection, and a pooled engine hands out connections
    # the override below did not visit. Set it on connect so every session this
    # factory creates is confined to this test's schema.
    if teardown_schema is not None:

        @event.listens_for(engine.sync_engine, "connect")
        def _set_search_path(dbapi_connection, _record) -> None:
            cursor = dbapi_connection.cursor()
            cursor.execute(f'SET search_path TO "{teardown_schema}"')
            cursor.close()

    factory = async_sessionmaker(
        bind=engine, class_=AsyncSession, expire_on_commit=False, autoflush=False
    )

    # Reference data is seeded the way a real deployment seeds it, in its own
    # committing session. Without it there are no course units to ask for help
    # with, and every test here would fail on missing reference data rather than
    # on the thing it exists to check.
    from app.db.seed import seed as seed_reference_data

    async with factory() as seed_session:
        await seed_reference_data(seed_session)

    async def _override_get_db() -> AsyncIterator[AsyncSession]:
        """Hand the request its own session, and close it when the request ends.

        Closing is the point. It is what turns an uncommitted write into a
        rollback, which is the behaviour this fixture exists to expose.
        """
        async with factory() as session:
            yield session

    app = create_app()
    app.dependency_overrides[get_db] = _override_get_db

    transport = ASGITransport(app=app, raise_app_exceptions=False)
    try:
        async with AsyncClient(
            transport=transport, base_url="http://testserver"
        ) as http_client:
            yield CommittedEnv(http_client, factory)
    finally:
        app.dependency_overrides.clear()
        if teardown_schema is not None:
            async with engine.begin() as connection:
                await connection.execute(
                    text(f'DROP SCHEMA "{teardown_schema}" CASCADE')
                )
        await engine.dispose()


@pytest.fixture
async def committed_client(committed_env: CommittedEnv) -> AsyncIterator[AsyncClient]:
    """The client from `committed_env`, for tests needing no direct database access."""
    yield committed_env.client


@pytest.fixture
async def client(db_session) -> AsyncIterator[AsyncClient]:
    """An HTTP client bound to the app, with exceptions left unhandled.

    `raise_app_exceptions=False` is deliberate: a route that returns a problem
    document is a normal outcome the test asserts on, not a test failure.

    The `get_db` override is what makes the requests above actually reach the
    test database. Without it the routes would use the process-wide engine from
    `app.core.database`, which is a different database from the one `db_session`
    is bound to -- so a test would write rows the test could not then read, and
    a suite exercising real requests would pass against rows it never wrote.

    The override has to be an async generator *function*, not a callable that
    returns one. FastAPI decides how to resolve a dependency by inspecting what
    it was given: given a generator function it iterates it, and given anything
    else it treats the result as the value. A lambda returning a generator is
    the second case, so the route would be handed the generator object itself
    and fail on the first query with an `async_generator has no attribute
    'execute'`.
    """
    from app.core.database import get_db
    from app.main import create_app

    async def _override_get_db() -> AsyncIterator[AsyncSession]:
        """Hand the request the test's own session.

        `get_db` is an async generator dependency, so this one is too. It does
        not open or close anything: the test owns the session's lifetime, and
        the point of the override is only to redirect which session the route
        is handed.
        """
        yield db_session

    app = create_app()
    app.dependency_overrides[get_db] = _override_get_db

    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(
        transport=transport, base_url="http://testserver"
    ) as http_client:
        yield http_client
