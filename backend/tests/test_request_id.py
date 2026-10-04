"""Request correlation: one id across a request's response and its logs."""

import logging

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.logging import RequestIdFilter
from app.core.request_id import REQUEST_ID_HEADER, normalize_request_id


def _header(response) -> str:
    return response.headers[REQUEST_ID_HEADER]


async def test_a_response_carries_a_request_id(client: AsyncClient) -> None:
    response = await client.get("/health")

    assert response.status_code == 200
    assert _header(response)


async def test_a_supplied_request_id_is_echoed_unchanged(
    client: AsyncClient,
) -> None:
    """A caller that already has an id -- a proxy, an SDK -- keeps it."""
    supplied = "0af7651916cd43dd8448eb211c80319c"
    response = await client.get("/health", headers={REQUEST_ID_HEADER: supplied})

    assert _header(response) == supplied


async def test_an_unsafe_request_id_is_replaced_not_echoed(
    client: AsyncClient,
) -> None:
    """The inbound id reaches logs, so it is untrusted input.

    A value that is a legal HTTP header but not a legal log token is replaced.
    Echoing it would let a caller choose what appears in the log stream.
    """
    response = await client.get(
        "/health", headers={REQUEST_ID_HEADER: "not a uuid; drop table"}
    )

    echoed = _header(response)
    assert echoed != "not a uuid; drop table"
    assert " " not in echoed
    assert ";" not in echoed


async def test_an_error_response_carries_the_request_id(client: AsyncClient) -> None:
    response = await client.get("/v1/nothing-here")

    assert response.status_code == 404
    assert _header(response)


async def test_a_supplied_id_is_echoed_on_an_error_too(client: AsyncClient) -> None:
    """The correlation value is only useful if the failing request keeps it."""
    supplied = "trace-me-1234"
    response = await client.get(
        "/v1/nothing-here", headers={REQUEST_ID_HEADER: supplied}
    )

    assert _header(response) == supplied


async def test_a_validation_error_carries_the_request_id(client: AsyncClient) -> None:
    response = await client.post("/v1/auth/register", json={})

    assert response.status_code == 422
    assert _header(response)


async def test_an_unhandled_error_carries_the_request_id() -> None:
    """The 500 path is the one that needs the id most.

    Starlette's unhandled-exception handler runs outside the request-id
    middleware, so this is the case that would silently lose the header.
    """
    from app.main import create_app

    app = create_app()

    @app.get("/v1/boom")
    async def _boom() -> None:
        raise RuntimeError("anything")

    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://testserver") as raw:
        response = await raw.get("/v1/boom")

    assert response.status_code == 500
    assert _header(response)


@pytest.mark.parametrize(
    "value",
    [
        "0af7651916cd43dd8448eb211c80319c",
        "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
        "ABC.Def_123-~",
    ],
)
def test_normalize_accepts_identifiers_value(value: str) -> None:
    assert normalize_request_id(value) == value


@pytest.mark.parametrize(
    "value",
    [
        None,
        "",
        "   ",
        "has space",
        "new\nline",
        "tab\there",
        "percent%s",
        "a" * 201,
    ],
)
def test_normalize_rejects_anything_that_is_not_a_token(value: str | None) -> None:
    assert normalize_request_id(value) is None


def test_the_log_filter_attaches_the_current_request_id() -> None:
    """The mechanism that puts the id on a record the formatter can render."""
    from app.core.request_id import _request_id

    record = logging.LogRecord("x", logging.INFO, "p", 1, "msg", None, None)
    token = _request_id.set("abc123")
    try:
        RequestIdFilter().filter(record)
    finally:
        _request_id.reset(token)

    assert record.request_id == "abc123"


def test_the_log_filter_defaults_outside_a_request() -> None:
    """A startup line has no request, and must still format."""
    record = logging.LogRecord("x", logging.INFO, "p", 1, "msg", None, None)

    RequestIdFilter().filter(record)

    assert record.request_id == "-"
