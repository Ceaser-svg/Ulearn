"""Credentials must not reach the logs.

The leak these guard against is real and was reproduced against PostgreSQL: a
statement error that escapes `register()`'s `except IntegrityError` reaches the
catch-all handler, which logs the traceback, and SQLAlchemy puts the failing
statement's bound parameters in that traceback -- including the Argon2 hash of
the password being registered.
"""

import logging

import pytest
from sqlalchemy import text

from app.core.logging import REDACTED, RedactingFilter, RedactingFormatter, redact


def test_a_password_hash_parameter_is_redacted() -> None:
    """The exact shape SQLAlchemy produces, since that is the whole threat."""
    line = (
        "sqlalchemy.exc.DataError: (psycopg.errors.StringDataRightTruncation)\n"
        "[SQL: INSERT INTO users (email, password_hash) VALUES (%(email)s, "
        "%(password_hash)s)]\n"
        "[parameters: {'email': 'a@mak.ac.ug', 'password_hash': "
        "'$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$Y3JlZGFuY2U'}]"
    )
    out = redact(line)

    assert "argon2id" not in out
    assert "Y3JlZGFuY2U" not in out, "the hash body survived redaction"
    assert "'email': 'a@mak.ac.ug'" in out, "a non-secret field was destroyed"
    assert "INSERT INTO users" in out, "the statement is needed to debug with"


@pytest.mark.parametrize(
    "key",
    [
        "password",
        "password_hash",
        "refresh_token",
        "access_token",
        "client_secret",
        "api_key",
        "authorization",
        "PIN",
        "otp",
    ],
)
def test_every_credential_shaped_key_is_redacted(key: str) -> None:
    out = redact(f"{{'{key}': 'super-secret-value'}}")
    assert "super-secret-value" not in out, key
    assert key in out, "the key itself should survive so the log stays useful"


def test_a_bare_password_hash_is_redacted_outside_a_parameter_dict() -> None:
    """Tracebacks carry hashes in prose too, not only as bound parameters."""
    out = redact("verify failed for $argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA")
    assert "argon2id" not in out


@pytest.mark.parametrize(
    "stored",
    [
        "$pbkdf2_sha256$260000$c2FsdA$aGFzaA",
        "$2b$12$c2FsdGEyNTY3ODkw$aGFzaGVkZ2U",
        "$scrypt$ln=1,r=8,p=1$c2FsdA$aGFzaA",
        "$argon2i$m=65536,t=3,p=4$c2FsdA$aGFzaA",
    ],
)
def test_legacy_and_alternative_hash_encodings_are_redacted(stored: str) -> None:
    """A hash this service no longer writes is still a hash worth removing."""
    assert redact(f"stored {stored}") == f"stored {REDACTED}"


def test_a_jwt_is_redacted() -> None:
    token = (
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"
        ".dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1"
    )
    out = redact(f"Authorization check failed for {token}")
    assert token not in out
    assert "Authorization check failed" in out


def test_database_url_credentials_are_redacted() -> None:
    out = redact(
        "could not connect to postgresql+psycopg://peerpass:hunter2@db.internal:5432/pp"
    )
    assert "hunter2" not in out
    assert "db.internal:5432/pp" in out, "the host is what identifies the failure"


def test_ordinary_text_is_untouched() -> None:
    line = "session 4f2c accepted for tutor 9a1b: 2 offers, 1 rated"
    assert redact(line) == line


def test_the_filter_keeps_the_stack_and_drops_the_secret() -> None:
    """The traceback is the part an operator needs; the hash is not."""
    records: list[logging.LogRecord] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            records.append(record)

    logger = logging.getLogger("test.redaction.sample")
    logger.handlers = [Capture()]
    logger.filters = [RedactingFilter()]
    logger.propagate = False
    logger.setLevel(logging.DEBUG)

    try:
        raise ValueError("$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaGVkZ2U")
    except ValueError:
        logger.exception("while registering")

    formatted = logging.Formatter("%(message)s").format(records[0])
    assert "aGFzaGVkZ2U" not in formatted
    assert "argon2id" not in formatted
    assert "ValueError" in formatted
    assert "while registering" in formatted
    assert "Traceback" in formatted, "the frames must survive redaction"


def test_the_formatter_redacts_a_plain_message() -> None:
    record = logging.LogRecord(
        name="x",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="token %s",
        args=("$argon2id$v=19$m=1,t=1,p=1$c2FsdA$aGFzaA",),
        exc_info=None,
    )
    out = RedactingFormatter("%(message)s").format(record)
    assert "argon2id" not in out
    assert REDACTED in out


async def test_a_failing_statement_does_not_log_its_parameters(
    db_engine, caplog
) -> None:
    """End to end: a real SQLAlchemy error, redacted on its way to a handler.

    The violation is a NOT NULL one on a different column while the parameter
    dict still carries the hash, which is the shape of the original leak and
    needs no dialect-specific trickery to produce -- it fails the same way on
    SQLite and on PostgreSQL.
    """
    logger = logging.getLogger("test.redaction.statement")
    logger.filters = [RedactingFilter()]
    logger.setLevel(logging.DEBUG)

    secret = "$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$cmVhbGhhc2g"
    with caplog.at_level(logging.DEBUG, logger="test.redaction.statement"):
        try:
            async with db_engine.begin() as connection:
                await connection.execute(
                    text(
                        "INSERT INTO users (email, password_hash) "
                        "VALUES ('a@mak.ac.ug', :secret)"
                    ),
                    {"secret": secret},
                )
        except Exception as exc:
            logger.error("insert failed", exc_info=exc)

    logged = "\n".join(
        r.getMessage() + "\n" + (r.exc_text or "") for r in caplog.records
    )
    assert "argon2id" not in logged, logged[:400]
    assert "c29tZXNhbHQ" not in logged, "the hash body survived"
    assert "a@mak.ac.ug" in logged, "the email is legitimate debug context"
