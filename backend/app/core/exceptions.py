"""Application exceptions, expressed as RFC 9457 problem details.

Every error the API returns to the client carries the same envelope, so the
Flutter client has one shape to parse. This is the reason the exceptions live in
`core` and the rendering happens once, in `main.py`: a route raises, and never
constructs a response body by hand.
"""

from typing import Any

from fastapi import status


class ProblemException(Exception):
    """An error with enough context to be rendered as problem details.

    `detail` is the human-readable explanation and is safe to show a student.
    Never put a stack trace, a SQL fragment, or a token in it: it is returned
    verbatim to an untrusted client.
    """

    def __init__(
        self,
        detail: str,
        *,
        status_code: int = status.HTTP_400_BAD_REQUEST,
        title: str | None = None,
        code: str | None = None,
        errors: dict[str, str] | None = None,
    ) -> None:
        super().__init__(detail)
        self.detail = detail
        self.status_code = status_code
        self.title = title or _DEFAULT_TITLES.get(status_code, "Error")
        self.code = code
        self.errors = errors or {}

    def to_problem(self, instance: str) -> dict[str, Any]:
        """The RFC 9457 document for this error."""
        problem: dict[str, Any] = {
            "type": f"https://peerpass.app/problems/{self.code or 'error'}",
            "title": self.title,
            "status": self.status_code,
            "detail": self.detail,
            "instance": instance,
        }
        if self.code is not None:
            problem["code"] = self.code
        if self.errors:
            problem["errors"] = self.errors
        return problem


class ValidationProblem(ProblemException):
    """One or more submitted values were rejected.

    `errors` maps a field name to its reason so the client can render the
    message beside the input that caused it.
    """

    def __init__(
        self,
        detail: str = "Some of the details you entered are not valid.",
        *,
        errors: dict[str, str] | None = None,
    ) -> None:
        super().__init__(
            detail,
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            title="Validation failed",
            code="validation_failed",
            errors=errors,
        )


class AuthenticationProblem(ProblemException):
    """Credentials are missing, expired, or insufficient to identify a caller.

    401. The remedy is to authenticate again, so that is what the message says.
    """

    def __init__(
        self,
        detail: str = "Your session has ended. Please sign in again.",
    ) -> None:
        super().__init__(
            detail,
            status_code=status.HTTP_401_UNAUTHORIZED,
            title="Authentication required",
            code="authentication_required",
        )


class AuthorizationProblem(ProblemException):
    """The caller is known but not permitted to do this.

    403, and worded differently from 401 on purpose: the two have different
    remedies, and hiding that would only make the error harder to act on. What
    the message must never contain is the internal reason -- a role name or a
    competency state would tell an attacker which account to go after.
    """

    def __init__(
        self,
        detail: str = "You do not have permission to do that.",
    ) -> None:
        super().__init__(
            detail,
            status_code=status.HTTP_403_FORBIDDEN,
            title="Not permitted",
            code="not_permitted",
        )


class NotFoundProblem(ProblemException):
    """The resource does not exist, or is not visible to this caller."""

    def __init__(self, detail: str = "That item could not be found.") -> None:
        super().__init__(
            detail,
            status_code=status.HTTP_404_NOT_FOUND,
            title="Not found",
            code="not_found",
        )


class TooManyRequestsProblem(ProblemException):
    """Too many attempts, and the caller has to wait.

    A distinct 429 rather than a 403 so a client can tell "you are not allowed"
    from "you are not allowed *yet*": the first needs a different account, the
    second needs patience. Collapsing them teaches every client to log the user
    out on a lockout.
    """

    def __init__(
        self,
        detail: str = "Too many attempts. Try again shortly.",
        *,
        retry_after_seconds: int | None = None,
    ) -> None:
        super().__init__(
            detail,
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            title="Too many requests",
            code="too_many_requests",
            errors=(
                {"retry_after_seconds": str(retry_after_seconds)}
                if retry_after_seconds is not None
                else None
            ),
        )


class ConflictProblem(ProblemException):
    """The request collided with existing state.

    Expected on a mobile client, where a retried request is normal. A retried
    accept of an already-accepted session should read as a conflict, not as a
    server fault.
    """

    def __init__(self, detail: str = "That has already changed.") -> None:
        super().__init__(
            detail,
            status_code=status.HTTP_409_CONFLICT,
            title="Conflict",
            code="conflict",
        )


_DEFAULT_TITLES = {
    400: "Bad request",
    401: "Authentication required",
    403: "Not permitted",
    404: "Not found",
    409: "Conflict",
    422: "Validation failed",
    429: "Too many requests",
    500: "Internal server error",
}
