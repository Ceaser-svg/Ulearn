"""The operator CLI provisions the first admin.

There is deliberately no HTTP route for this. Every user of any role must be
able to reach the API, and a route that grants `UserRole.ADMIN` is a route that
either trusts an unauthenticated caller or is useless. Provisioning is a
deployment step, so it lives in `python -m app.cli create-admin`.

These tests run the real function against a real database. They do not mock
`hash_password`, because the point of the test is that the CLI hashes with the
same function and under the same password policy as sign-up. A CLI that hashed
differently would leave an operator with an account unlike every other account
in the system, and nothing on the login screen would reveal it.
"""

import pytest
from sqlalchemy import select

from app.cli import BOOTSTRAP_ACTION, create_admin, main
from app.core.exceptions import ConflictProblem, ValidationProblem
from app.core.security import verify_password
from app.models.audit import AdminAuditEvent
from app.models.enums import UserRole
from app.models.user import load_roles
from app.services.auth_service import load_user_by_email


async def test_a_bootstrap_admin_is_created_with_the_admin_role(
    committed_env,
) -> None:
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        created = await create_admin(
            db,
            email="bootstrap@peerpass.co.ug",
            password="correct horse battery staple 42",
            full_name="First Admin",
        )
    assert created.public_id is not None
    assert created.full_name == "First Admin"


async def test_a_bootstrap_admin_can_verify_its_password_against_the_same_hash(
    committed_env,
) -> None:
    """The Argon2 path is the shared one, not a lookalike."""
    password = "correct horse battery staple 42"
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        await create_admin(
            db, email="verify@peerpass.co.ug", password=password, full_name=None
        )

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        user = await load_user_by_email(db, "verify@peerpass.co.ug")
        assert user is not None
        assert user.password_hash.startswith("$argon2")
        assert verify_password(password, user.password_hash) is True


async def test_a_bootstrap_admin_holds_only_the_admin_role(committed_env) -> None:
    """Admin, not admin-and-student.

    An operator account that also carried the student role would appear in the
    tutor rail and in student-facing lists, which is not what anyone wants from
    the person running the deployment.
    """
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        await create_admin(
            db,
            email="roles@peerpass.co.ug",
            password="correct horse battery staple 42",
            full_name=None,
        )

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        user = await load_user_by_email(db, "roles@peerpass.co.ug")
        assert user is not None
        roles = await load_roles(db, user.id)
        assert roles == {UserRole.ADMIN}


async def test_the_bootstrap_writes_an_audit_event_naming_itself(committed_env) -> None:
    """The one account not created by another admin must still be visible later.

    `actor_id` is non-nullable, so the account is its own actor. A reviewer
    scanning the audit log needs to be able to tell that this row is a bootstrap
    rather than an operator acting through the console.
    """
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        admin = await create_admin(
            db,
            email="audited@peerpass.co.ug",
            password="correct horse battery staple 42",
            full_name=None,
        )

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        events = (
            (
                await db.execute(
                    select(AdminAuditEvent).where(
                        AdminAuditEvent.action == BOOTSTRAP_ACTION
                    )
                )
            )
            .scalars()
            .all()
        )
        assert len(events) == 1
        event = events[0]
        assert event.actor_id == admin.id
        assert event.target_public_id == admin.public_id
        assert event.context["source"] == "cli"
        assert event.context["self_attested"] is True


async def test_the_audit_context_holds_no_password(committed_env) -> None:
    """The audit table must not become a second sensitive-data store.

    It stores identifiers and an email. Nothing derived from the password may
    appear, or a dump of the audit log becomes a credential store.
    """
    password = "correct horse battery staple 42"
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        await create_admin(
            db, email="leak@peerpass.co.ug", password=password, full_name=None
        )

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        event = (
            (
                await db.execute(
                    select(AdminAuditEvent).where(
                        AdminAuditEvent.action == BOOTSTRAP_ACTION
                    )
                )
            )
            .scalars()
            .one()
        )
        rendered = repr(event.context)
        assert password not in rendered
        assert "argon2" not in rendered


async def test_bootstrapping_twice_refuses_instead_of_resetting_the_password(
    committed_env,
) -> None:
    """Re-running must not become a password reset.

    Resetting an existing administrator's password from a shell is the
    capability that turns a leaked session ticket into a permanent takeover, so
    the tool declines rather than treating a second run as a repair.
    """
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        first = await create_admin(
            db,
            email="twice@peerpass.co.ug",
            password="correct horse battery staple 42",
            full_name=None,
        )
        original_hash = first.password_hash

        with pytest.raises(ConflictProblem) as caught:
            await create_admin(
                db,
                email="twice@peerpass.co.ug",
                password="a completely different password 99",
                full_name=None,
            )
        assert "does not" in str(caught.value)

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        user = await load_user_by_email(db, "twice@peerpass.co.ug")
        assert user is not None
        assert user.password_hash == original_hash


async def test_the_email_is_normalised_the_way_sign_in_normalises_it(
    committed_env,
) -> None:
    """Mixed case and surrounding whitespace must not create a second account.

    The unique index would stop it anyway, but as an IntegrityError out of a CLI
    rather than as a clear message.
    """
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        created = await create_admin(
            db,
            email="  MixedCase@PeerPass.co.ug  ",
            password="correct horse battery staple 42",
            full_name=None,
        )
    assert created.email == created.email.strip().lower()

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        again = await load_user_by_email(db, "mixedcase@peerpass.co.ug")
        assert again is not None
        assert again.id == created.id


async def test_a_password_the_app_would_refuse_is_refused_here_too(
    committed_env,
) -> None:
    """Same policy as sign-up. A weaker bootstrap password would be a real gap."""
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        with pytest.raises(ValidationProblem):
            await create_admin(
                db, email="weak@peerpass.co.ug", password="short", full_name=None
            )


async def test_the_cli_main_refuses_a_mismatched_confirmation(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The two-prompt path must not proceed on a typo."""
    prompts = iter(["one password 12345", "a different one 67890"])
    monkeypatch.setattr("app.cli.getpass.getpass", lambda _prompt: next(prompts))

    def _unreachable() -> None:
        raise AssertionError("the database must not be reached")

    monkeypatch.setattr("app.cli._run_create_admin", _unreachable)

    assert main(["create-admin", "--email", "typo@peerpass.co.ug"]) == 2
    assert "did not match" in capsys.readouterr().err


async def test_the_cli_main_reports_a_refusal_as_a_nonzero_exit(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A deployment script needs to see failure, not a zero exit and a message."""
    monkeypatch.setattr("app.cli.getpass.getpass", lambda _prompt: "short")
    monkeypatch.setattr("app.cli.asyncio.run", _raise_conflict)

    assert main(["create-admin", "--email", "taken@peerpass.co.ug"]) == 2
    assert "Refused" in capsys.readouterr().err


def _raise_conflict(coro):
    """Close the coroutine `main` built, then report the refusal it would raise."""
    coro.close()
    raise ConflictProblem("An account already exists for taken@peerpass.co.ug.")


async def test_an_address_the_sign_in_route_would_refuse_is_refused_here(
    committed_env,
) -> None:
    """The CLI must not mint an account nobody can sign in to.

    Found by smoke-testing the real command: `--email ops@peerpass.test`
    succeeded, then `POST /v1/auth/login` returned 422 because pydantic's
    `EmailStr` rejects the reserved `.test` TLD. An operator would have been told
    the account was created, and found at the login screen that it was not.
    """
    async with committed_env.session() as db:  # type: ignore[attr-defined]
        with pytest.raises(ValidationProblem) as caught:
            await create_admin(
                db,
                email="ops@peerpass.test",
                password="correct horse battery staple 42",
                full_name=None,
            )
        assert "email" in caught.value.errors

    async with committed_env.session() as db:  # type: ignore[attr-defined]
        assert await load_user_by_email(db, "ops@peerpass.test") is None
