"""Operator commands that run against the database from outside the API.

Run them with `python -m app.cli <command>`. These exist because some actions
have no HTTP route on purpose: provisioning the first administrator is a
deployment task, not something a signed-in user of any role may trigger, and
putting it behind an endpoint would mean either shipping a route that grants
itself authority or requiring an admin to already exist.

Read the password from the terminal rather than from a flag. A password on the
command line is visible in `ps` to every other process on the machine and is kept
in shell history; `getpass` avoids both. No subcommand takes a password as an
argument.
"""

import argparse
import asyncio
import getpass
import sys

from pydantic import EmailStr, TypeAdapter, ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_session_factory
from app.core.exceptions import ConflictProblem, ValidationProblem
from app.core.password_policy import denial_reason
from app.core.security import hash_password
from app.models.audit import AdminAuditEvent
from app.models.enums import UserRole
from app.models.user import User, set_roles
from app.services.auth_service import load_user_by_email, normalise_email

#: Identifies this action in `admin_audit_events.action`. Recorded so that the
#: one account which was not created by another administrator is still visible
#: to whoever reviews the audit log later.
BOOTSTRAP_ACTION = "admin_bootstrap.created"

#: `EmailStr` is an annotated alias rather than a class, so it has to be run
#: through an adapter to be usable outside a model.
_EMAIL_ADAPTER = TypeAdapter(EmailStr)


async def create_admin(
    db: AsyncSession, *, email: str, password: str, full_name: str | None
) -> User:
    """Create an administrator account, and say plainly if it already exists.

    Goes through the same `hash_password` and `denial_reason` the registration
    route uses rather than reimplementing either. A bootstrap that hashed more
    weakly, or accepted a password the app would later refuse, would leave an
    operator with an account that behaves unlike every other account in the
    system -- and the difference would not be visible from the login screen.

    Idempotent in the sense that matters here: re-running with the same address
    fails loudly instead of silently resetting the password. Resetting an
    existing administrator's password from a shell is exactly the capability
    that turns a leaked session ticket into a permanent account takeover, so
    the tool declines to do it. Use the API's own admin tooling for that.
    """
    reason = denial_reason(password)
    if reason is not None:
        raise ValidationProblem(
            "That password cannot be accepted.", errors={"password": reason}
        )

    # Validation and storage are deliberately different steps. Pydantic's
    # `EmailStr` decides whether the address is usable at all -- it rejects
    # reserved and special-use domains, which the sign-in route also rejects --
    # but it preserves the local part's case. `normalise_email` is what
    # registration uses to *store* an address. Doing only one of the two leaves
    # the bootstrap and sign-up paths disagreeing about how `Ops@Example.com` is
    # spelled, and that surfaces days later at the login screen with no cause.
    #
    # Without the validation step this command mints an account nobody can sign
    # in to, while reporting success: `ops@peerpass.test` is created happily and
    # then refused by `POST /v1/auth/login` with a 422.
    try:
        _EMAIL_ADAPTER.validate_python(email)
    except ValidationError as exc:
        raise ValidationProblem(
            "That email address cannot be used.", errors={"email": str(exc)}
        ) from exc

    normalised = normalise_email(email)

    # Look the address up the same way sign-in does. Comparing the raw argument
    # here instead would let "Admin@X " and "admin@x" both pass this check and
    # then collide on the unique index.
    if await load_user_by_email(db, normalised) is not None:
        raise ConflictProblem(
            f"An account already exists for {normalised}. This command does not "
            "reset an existing password."
        )

    user = User(
        email=normalised,
        full_name=full_name,
        password_hash=hash_password(password),
    )
    db.add(user)
    await db.flush()

    await set_roles(db, user.id, {UserRole.ADMIN})

    # The account is its own actor. `actor_id` is deliberately non-nullable
    # because an audit row with no actor is the kind of thing an auditor cannot
    # use, and inventing a system user to fill it would be worse than a
    # self-attesting bootstrap event that is plainly labelled as one.
    db.add(
        AdminAuditEvent(
            actor_id=user.id,
            action=BOOTSTRAP_ACTION,
            target_type="user",
            target_public_id=user.public_id,
            # Normalised, so the audit log cannot hold two spellings of the
            # one address.
            context={
                "email": user.email,
                "source": "cli",
                "self_attested": True,
            },
        )
    )

    await db.commit()
    return user


def _run_create_admin(args: argparse.Namespace) -> int:
    async def _run() -> User:
        async with get_session_factory()() as session:
            return await create_admin(
                session,
                email=args.email,
                password=args.password,
                full_name=args.name,
            )

    user = asyncio.run(_run())
    print(f"Created administrator {user.email}")
    print(f"  public id : {user.public_id}")
    print("  sign in from the admin console with this email and password.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m app.cli", description="PeerPass operator commands."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser(
        "create-admin",
        help="Create the first administrator account.",
        description=(
            "Create an administrator. Fails if the address already has an "
            "account; this command never resets an existing password."
        ),
    )
    create.add_argument("--email", required=True, help="Administrator email address.")
    create.add_argument(
        "--name", default=None, help="Display name. Defaults to unset, as sign-up does."
    )
    create.add_argument(
        "--password-stdin",
        action="store_true",
        help=(
            "Read the password from stdin instead of the terminal. For use in "
            "an automated deployment; prefer the prompt where possible."
        ),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "create-admin":
        if args.password_stdin:
            args.password = sys.stdin.readline().rstrip("\n")
        else:
            first = getpass.getpass("Password: ")
            second = getpass.getpass("Confirm password: ")
            if first != second:
                print("Passwords did not match.", file=sys.stderr)
                return 2
            args.password = first
        try:
            return _run_create_admin(args)
        except ValidationProblem as exc:
            print(f"Refused: {exc.detail}", file=sys.stderr)
            for field, reason in (exc.errors or {}).items():
                print(f"  {field}: {reason}", file=sys.stderr)
            return 2
        except ConflictProblem as exc:
            print(f"Refused: {exc.detail}", file=sys.stderr)
            return 2


if __name__ == "__main__":
    raise SystemExit(main())
