"""Give every request one identifier, across its logs and its response.

An operator reading a 500 in the logs and a student reporting an error have no
shared handle without this, and neither does a proxy's access log. The identifier
is echoed in `X-Request-ID` so a bug report can name one request out of
thousands, and attached to every log record emitted while that request is being
handled so the lines can be read together.

The inbound value is untrusted. It is echoed into a response header and into log
text, so a newline or a logging-format directive in it is an injection primitive.
It is validated to a conservative charset and length and replaced with a freshly
generated id when it does not fit -- replaced rather than rejected, because a
malformed correlation id is not a reason to fail the request that carried it.
"""

from __future__ import annotations

import logging
import re
import uuid
from contextvars import ContextVar
from typing import TYPE_CHECKING

from starlette.datastructures import Headers

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable, MutableMapping
    from typing import Any

    Scope = MutableMapping[str, Any]
    Message = MutableMapping[str, Any]
    Receive = Callable[[], Awaitable[Message]]
    Send = Callable[[Message], Awaitable[None]]
    ASGIApp = Callable[[Scope, Receive, Send], Awaitable[None]]

REQUEST_ID_HEADER = "X-Request-ID"

#: Lowercase, because that is how ASGI carries header names.
_REQUEST_ID_HEADER_BYTES = REQUEST_ID_HEADER.lower().encode("ascii")

#: The id of the request being handled, or None outside one.
#:
#: A context variable rather than a parameter threaded through every function:
#: the value is needed by the logging filter, which is two layers of framework
#: below the middleware and cannot be handed an argument. `ContextVar` also does
#: the right thing under concurrency -- each request's task sees its own value,
#: where a module-level attribute would be shared and wrong.
_request_id: ContextVar[str | None] = ContextVar("request_id", default=None)
_logger = logging.getLogger(__name__)

#: What an outbound-safe identifier is allowed to contain.
#:
#: Deliberately an allowlist. UUIDs, hex trace ids, and W3C `traceparent` values
#: all match; a newline, a `%s`, or a control character does not. Uppercase is
#: allowed because several load balancers emit it.
_SAFE_REQUEST_ID = re.compile(r"\A[A-Za-z0-9._~-]{1,200}\Z")


def normalize_request_id(value: str | None) -> str | None:
    """Return [value] when it is safe to echo and log, else None.

    Exposed rather than private because the same rule has to hold anywhere an
    id from outside reaches log text, and a second copy of it would drift.
    """
    if value is None:
        return None

    candidate = value.strip()
    if not candidate or not _SAFE_REQUEST_ID.match(candidate):
        return None
    return candidate


def current_request_id() -> str | None:
    """The id of the request being handled, or None outside a request."""
    return _request_id.get()


def new_request_id() -> str:
    """A fresh identifier, when the caller did not supply a usable one."""
    return str(uuid.uuid4())


class RequestIdMiddleware:
    """Attach a request id to the scope, the logs, and the response.

    Pure ASGI rather than `BaseHTTPMiddleware`. The higher-level class runs the
    inner app in a separate task, and a context variable set before that boundary
    is not the one the request's own logs read; the whole point here is that the
    endpoint's log records see the id the middleware chose.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = normalize_request_id(
            Headers(scope=scope).get(_REQUEST_ID_HEADER_BYTES.decode("ascii"))
        )
        request_id = incoming or new_request_id()

        # On the scope as well as the context variable: exception handlers that
        # run *outside* this middleware -- Starlette's unhandled-exception
        # handler does -- read `request.state`, and have already lost the
        # context variable by the time they run.
        scope.setdefault("state", {})["request_id"] = request_id
        token = _request_id.set(request_id)

        async def send_with_request_id(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                if not any(
                    key.lower() == _REQUEST_ID_HEADER_BYTES for key, _ in headers
                ):
                    headers.append(
                        (_REQUEST_ID_HEADER_BYTES, request_id.encode("ascii"))
                    )
                message["headers"] = headers
            await send(message)

        try:
            await self.app(scope, receive, send_with_request_id)
        except BaseException:
            # ServerErrorMiddleware logs after this middleware unwinds and has
            # already lost the context variable. Emit the correlated record
            # while this request's ID is still installed, then preserve the
            # original exception for the outer error handler.
            _logger.exception("Unhandled error in request middleware")
            raise
        finally:
            _request_id.reset(token)
