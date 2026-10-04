"""Keep credentials out of the logs.

SQLAlchemy puts the bound parameters of a failed statement into the text of the
exception it raises. That text is normally swallowed -- `register()` catches the
`IntegrityError` from a duplicate address and answers 409 -- but the guard is
specific to one exception type. A `DataError` from a mis-sized column, an
`OperationalError` from a deadlock, anything else that escapes the flush reaches
the catch-all handler in `main.py`, which logs the traceback. That traceback
carries the INSERT that creates an account, and therefore the student's Argon2
hash and email address in cleartext:

    sqlalchemy.exc.DataError: (psycopg.errors.StringDataRightTruncation)
    value too long for type character varying(12)
    [SQL: INSERT INTO users (...) VALUES (%(email)s, %(password_hash)s, ...)]
    [parameters: {'email': '...', 'password_hash': '$argon2id$v=19$m=65536...'}]

A password hash is not a password, but it is the whole credential database to an
attacker with a GPU and a list of candidate passwords, and an Argon2 hash in a
log store outlives the incident that produced it. The same text also carries
email addresses, which for this product are student identities.

So redaction happens at the logging boundary rather than at each throw site.
Every place that formats a log record goes through here, which means a new code
path cannot leak by forgetting to opt in -- the failure mode of a per-call-site
filter is that the one place nobody remembered is the one that leaks.
"""

import logging
import re

#: The parameter names whose values must never be logged. Matched as whole words
#: inside a quoted key, so `password_hash` is caught by `password` and not by
#: something like `password_policy_id`.
_SENSITIVE_KEY = re.compile(
    r"""(?P<quote>['"])(?P<key>[A-Za-z0-9_]*(?:password|passwd|secret|token|api_key|apikey|authorization|credential|private_key|pin|otp)[A-Za-z0-9_]*)(?P=quote)"""
    r"""\s*[:=]\s*"""
    r"""(?P<value>'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|None|True|False)""",
    re.IGNORECASE,
)

#: A password hash, wherever it appears. An encoded hash opens with an explicit
#: scheme marker, which is what makes it unambiguous in running text: `$2b$` is a
#: bcrypt cost factor and nothing else, `$argon2id$` is an Argon2 variant.
#: Note the optional suffix on each scheme -- PBKDF2 writes `pbkdf2_sha256` and
#: bcrypt writes `2b`, so a pattern that assumed the `$` came straight after the
#: family name would miss exactly the legacy formats most worth redacting.
_PASSWORD_HASH = re.compile(
    r"\$(?:argon2[a-z0-9]{0,2}|pbkdf2(?:_[a-z0-9]+)?|scrypt|bcrypt|2[abxy]"
    r"|sha(?:256|512))\$[^\s'\"]+",
    re.IGNORECASE,
)

#: A three-segment JWT. The segments are what make this safe to match: base64url
#: on its own is indistinguishable from an ordinary long identifier.
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b")

#: Credentials inside a connection string, which is how a database URL lands in a
#: log whenever a connection fails.
_URL_CREDENTIALS = re.compile(
    r"(?P<scheme>[a-zA-Z0-9+]+://)(?P<user>[^:/@\s]+):(?P<password>[^@/\s]+)@"
)

REDACTED = "[redacted]"


def redact(message: str) -> str:
    """Remove credential-shaped values from one piece of log text.

    Operates on the whole rendered record rather than on individual fields,
    because the interesting cases are not fields: an Argon2 hash inside a
    traceback, a connection string inside a driver error, a bearer token inside
    an HTTP client's debug log. All of them are just substrings once formatted.

    Deliberately not a parser. Anything clever enough to know whether a
    particular key is secret in a particular statement is also wrong the first
    time a statement is built by a library rather than by us, and this runs on
    every log line in the service. Redacting a key that turns out not to be
    sensitive costs a debugging session; failing to redact one that is costs the
    credential.
    """
    if not message:
        return message

    message = _SENSITIVE_KEY.sub(
        lambda m: f"{m['quote']}{m['key']}{m['quote']}: {REDACTED}", message
    )
    message = _PASSWORD_HASH.sub(REDACTED, message)
    message = _JWT.sub(REDACTED, message)
    message = _URL_CREDENTIALS.sub(
        lambda m: f"{m['scheme']}{m['user']}:{REDACTED}@", message
    )
    return message


class RedactingFilter(logging.Filter):
    """Redact a record on its way to a handler.

    A filter rather than a formatter, because a filter attaches to a *logger* and
    so survives whatever the process that owns logging does to its handlers. The
    application is served by uvicorn, which installs its own logging configuration
    at startup; a formatter attached at import time is discarded when it does.

    `exc_text` is the hook. `logging.Formatter.format` only renders a traceback
    when `exc_text` is unset, so pre-computing it here -- redacted -- means the
    real formatter appends this text instead of rendering the original exception.
    That keeps the stack frames, which is the part an operator actually needs,
    rather than replacing the traceback with a single opaque line.
    """

    def __init__(self) -> None:
        super().__init__()
        self._formatter = logging.Formatter()

    def filter(self, record: logging.LogRecord) -> bool:
        if record.exc_info and not record.exc_text:
            try:
                record.exc_text = self._formatter.formatException(record.exc_info)
            except Exception:  # pragma: no cover - never break logging
                record.exc_text = "[traceback could not be formatted]"
        if record.exc_text:
            record.exc_text = redact(record.exc_text)

        if isinstance(record.msg, str):
            record.msg = redact(record.msg)
        if record.args:
            record.args = tuple(
                redact(arg) if isinstance(arg, str) else arg for arg in record.args
            )
        return True


class RedactingFormatter(logging.Formatter):
    """A formatter that redacts its output.

    Defence in depth for handlers this process installs itself, where the filter
    above would not otherwise be in the path.
    """

    def format(self, record: logging.LogRecord) -> str:
        return redact(super().format(record))


def install_log_redaction() -> None:
    """Route every handler's output through redaction.

    Idempotent, and safe to call from anywhere: application startup, a CLI, a
    test. Attaching to the root handlers covers loggers that propagate to them,
    which is all of them by default.
    """
    root = logging.getLogger()
    if not any(isinstance(f, RedactingFilter) for f in root.filters):
        root.addFilter(RedactingFilter())

    if not root.handlers:
        # No handler of our own yet -- uvicorn installs its configuration after
        # this module is imported. Rather than depend on that happening, add a
        # handler that will not emit anything unless the level is reached.
        root.addHandler(logging.StreamHandler())

    for handler in root.handlers:
        if not any(isinstance(f, RedactingFilter) for f in handler.filters):
            handler.addFilter(RedactingFilter())
        if not isinstance(handler.formatter, RedactingFormatter):
            handler.setFormatter(
                RedactingFormatter("%(levelname)s %(name)s %(message)s")
            )
