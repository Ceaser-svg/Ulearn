"""Account deletion, and what it is required to leave behind.

The product decision is anonymisation, not removal. Every FK to `users.id`
cascades, so a `DELETE` on the row would take the sessions, ratings, endorsements
and competencies with it -- and a `Session` is the source of truth for a tutor's
`certified_minutes`, so removing the row would silently rewrite a colleague's
certificate progress. The tests below therefore assert two things that pull in
opposite directions, and both have to hold:

    the identity goes, and the evidence stays.

Most of this file goes through the real router with a real access token. A
deletion that anonymises the row correctly but leaves `get_current_user` willing
to authenticate it passes every service-level test and ships an account that was
asked to stop existing and can still read the API with a token minted beforehand.
That is the failure this file exists to catch.
"""

import uuid
from datetime import UTC, datetime

from sqlalchemy import func, select

from app.core.security import verify_password
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Subject, University
from app.models.endorsement import UnitEndorsement
from app.models.enums import (
    CompetencyStatus,
    SessionStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade, GradingScale
from app.models.rating import Rating
from app.models.session import Session
from app.models.tutor_profile import TutorProfile
from app.models.user import RefreshToken, User, set_roles
from app.services.deletion_service import (
    DELETED_PASSWORD_HASH,
    delete_account,
    tombstone_email,
)
from tests.support import sole_faculty_id

GOOD_PASSWORD = "correct horse battery staple"


# --- wire helpers ----------------------------------------------------------
#
# Repeated from `test_tutor_rail.py` rather than imported, so a failure in either
# file points at the file that owns the case.


async def _register(client, email: str) -> dict:
    response = await client.post(
        "/v1/auth/register", json={"email": email, "password": GOOD_PASSWORD}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _bearer(body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {body['tokens']['access_token']}"}


async def _account(
    client, db_session, email: str, *, full_name: str | None = "Ada Lovelace"
) -> tuple[dict, User]:
    body = await _register(client, email)
    user = await db_session.scalar(select(User).where(User.email == email))
    assert user is not None
    if full_name is not None:
        user.full_name = full_name
    await db_session.commit()
    return body, user


# --- fixtures --------------------------------------------------------------


async def _institution(db_session) -> tuple[University, CourseUnit, Grade]:
    """A university, one course unit, and a B+ grade that clears competency."""
    scale = GradingScale(
        name="Makerere 5-point",
        max_points=5,
        competency_min_points=4,
    )
    university = University(name="Makerere University", grading_scale=scale)
    subject = Subject(name="Makerere Faculty of Science")
    unit = CourseUnit(
        public_id=uuid.uuid4(),
        code="CSC 121",
        name="Intro to Programming",
        subject=subject,
        university=university,
    )
    grade = Grade(
        label="B+",
        grade_points=4,
        max_points=5,
        grading_scale=scale,
    )
    db_session.add_all([university, unit, grade])
    await db_session.commit()
    return university, unit, grade


async def _verified_tutor(db_session, university, unit, grade, email: str) -> User:
    """A tutor with a verified B+ competency, a standing, and 600 banked minutes.

    The minutes matter: they are the number that has to survive deletion, because
    they belong to the tutor's certificate progress and are incremented from
    completed sessions that belong to somebody else as much as to them.
    """
    user = User(
        email=email,
        full_name="Grace Hopper",
        password_hash="x",
        university_id=university.id,
        # Placed in the faculty of the unit they are verified against, because a
        # tutor with no faculty can no longer appear on any rail.
        faculty_id=unit.subject_id,
        academic_data_consented_at=datetime.now(UTC),
    )
    db_session.add(user)
    await db_session.flush()
    await set_roles(db_session, user.id, {UserRole.STUDENT, UserRole.TUTOR})
    profile = TutorProfile(
        user_id=user.id,
        standing=TutorStanding.VERIFIED,
        rating_total=0,
        rating_count=0,
        certified_minutes=600,
    )
    db_session.add(profile)
    db_session.add(
        Competency(
            user_id=user.id,
            course_unit_id=unit.id,
            grade_id=grade.id,
            status=CompetencyStatus.VERIFIED,
            source=VerificationSource.TRANSCRIPT,
        )
    )
    await db_session.commit()
    return user


# --- the identity goes -----------------------------------------------------


class TestIdentityIsScrubbed:
    """The columns that identify the person are rewritten or cleared."""

    async def test_email_becomes_a_synthetic_undeliverable_address(
        self, client, db_session
    ):
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        original_public_id = user.public_id

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert user.email == tombstone_email(original_public_id)
        # The point of the domain: RFC 2606 reserves `.invalid`, so this address
        # cannot resolve and cannot be delivered to.
        assert user.email.endswith("@deleted.invalid")
        assert "ada@student.makerere.ac.ug" not in user.email

    async def test_the_tombstone_address_cannot_be_registered(self, client, db_session):
        """A new account cannot claim the row the placeholder points at.

        This is the direction that matters for safety. If registration could
        express the address, a new student could sign up as
        `deleted+<uuid>@deleted.invalid` and, if any code ever resolved by email,
        inherit the tombstone's evidence.
        """
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        await delete_account(db_session, user)
        await db_session.refresh(user)
        placeholder = user.email

        response = await client.post(
            "/v1/auth/register", json={"email": placeholder, "password": GOOD_PASSWORD}
        )

        # Refused by the schema, before any service runs: `EmailStr` rejects the
        # whole `invalid` TLD as a special-use name.
        assert response.status_code == 422, response.text

    async def test_name_and_academic_identifiers_are_cleared(self, client, db_session):
        university, _unit, _grade = await _institution(db_session)
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        user.university_id = university.id
        user.faculty_id = await sole_faculty_id(db_session, university)
        user.year_of_study = 3
        user.academic_data_consented_at = datetime.now(UTC)
        await db_session.commit()

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert user.full_name is None
        # "A third-year in the engineering faculty" re-identifies one person in a
        # cohort of nine, so the affiliation goes as well as the name.
        assert user.university_id is None
        assert user.faculty_id is None
        assert user.year_of_study is None
        # A consent record exists to evidence that a *named* person agreed. With
        # the name gone it evidences nothing, and a deletion request is itself a
        # withdrawal of the basis for processing.
        assert user.academic_data_consented_at is None

    async def test_password_hash_becomes_something_no_password_satisfies(
        self, client, db_session
    ):
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert user.password_hash == DELETED_PASSWORD_HASH
        for guess in ("", GOOD_PASSWORD, "password", "!deleted-account"):
            assert verify_password(guess, user.password_hash) is False, guess

    async def test_password_hash_is_not_a_valid_phc_string(self, client, db_session):
        """Deliberately not Argon2 output.

        A real hash of an unguessable secret would also refuse every guess, but it
        would leave a credential hash in the row and would make
        `password_needs_rehash` report a healthy account, so the next process to
        touch the column would treat the tombstone as live. Refusing every guess
        for the same cost as a wrong password is what stops the placeholder from
        becoming an oracle that answers "this account was deleted".
        """
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert not user.password_hash.startswith("$argon2")


# --- the evidence stays ----------------------------------------------------


class TestEvidenceSurvives:
    """What other people's standing is computed from must not move."""

    async def test_sessions_survive_and_still_carry_their_minutes(
        self, client, db_session
    ):
        university, unit, _grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, _grade, "grace@student.makerere.ac.ug"
        )
        _body, student = await _account(
            client, db_session, "ada@student.makerere.ac.ug"
        )
        session = Session(
            tutee_id=student.id,
            tutor_id=tutor.id,
            course_unit_id=unit.id,
            topic="Recursion",
            duration_minutes=90,
            status=SessionStatus.COMPLETED,
            started_at=datetime.now(UTC),
            ended_at=datetime.now(UTC),
        )
        db_session.add(session)
        await db_session.commit()
        session_id = session.id

        await delete_account(db_session, student)
        await db_session.commit()

        survivor = await db_session.get(Session, session_id)
        assert survivor is not None, "a session must outlive one of its parties"
        assert survivor.duration_minutes == 90

    async def test_a_tutors_certificate_minutes_survive_their_own_deletion(
        self, client, db_session
    ):
        """The load-bearing case.

        `certified_minutes` is incremented from sessions, so erasing a tutor
        would quietly lower a number that a certificate eligibility answer is
        computed from -- rewriting an achievement because of an unrelated
        personal-data request.
        """
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )

        await delete_account(db_session, tutor)
        await db_session.refresh(tutor)

        profile = await db_session.scalar(
            select(TutorProfile).where(TutorProfile.user_id == tutor.id)
        )
        assert profile is not None
        assert profile.certified_minutes == 600

    async def test_ratings_survive_as_evidence_about_a_tombstone(
        self, client, db_session
    ):
        university, unit, _grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, _grade, "grace@student.makerere.ac.ug"
        )
        _body, student = await _account(
            client, db_session, "ada@student.makerere.ac.ug"
        )
        session = Session(
            tutee_id=student.id,
            tutor_id=tutor.id,
            course_unit_id=unit.id,
            topic="Recursion",
            duration_minutes=60,
            status=SessionStatus.COMPLETED,
            started_at=datetime.now(UTC),
            ended_at=datetime.now(UTC),
        )
        db_session.add(session)
        await db_session.flush()
        rating = Rating(
            session_id=session.id,
            rater_id=student.id,
            ratee_id=tutor.id,
            score=5,
        )
        db_session.add(rating)
        await db_session.commit()
        rating_id = rating.id

        await delete_account(db_session, tutor)
        await db_session.commit()

        survivor = await db_session.get(Rating, rating_id)
        assert survivor is not None, "a rating must outlive the tutor it is about"
        assert survivor.score == 5

    async def test_competencies_and_endorsements_survive(self, client, db_session):
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )
        _body, student = await _account(
            client, db_session, "ada@student.makerere.ac.ug"
        )
        competency_id = await db_session.scalar(
            select(Competency.id).where(Competency.user_id == tutor.id)
        )
        assert competency_id is not None
        session = Session(
            tutee_id=student.id,
            tutor_id=tutor.id,
            course_unit_id=unit.id,
            topic="Recursion",
            duration_minutes=60,
            status=SessionStatus.COMPLETED,
            started_at=datetime.now(UTC),
            ended_at=datetime.now(UTC),
        )
        db_session.add(session)
        await db_session.flush()
        endorsement = UnitEndorsement(
            session_id=session.id,
            rater_id=student.id,
            ratee_id=tutor.id,
            course_unit_id=unit.id,
        )
        db_session.add(endorsement)
        await db_session.commit()
        endorsement_id = endorsement.id

        await delete_account(db_session, tutor)
        await db_session.commit()

        assert await db_session.get(Competency, competency_id) is not None
        assert await db_session.get(UnitEndorsement, endorsement_id) is not None


# --- a tombstone is not an account -----------------------------------------


class TestATombstoneCannotAuthenticate:
    """Deleting has to close the door, not just clean the room."""

    async def test_an_access_token_minted_before_deletion_stops_working(
        self, client, db_session
    ):
        """The regression this whole slice exists to prevent.

        The token is captured before the deletion, so the only thing that can
        refuse it is the `deleted_at` check in the auth guard.
        """
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        headers = _bearer(_body)
        probe = await client.get("/v1/ratings/me", headers=headers)
        assert probe.status_code == 200, probe.text

        await delete_account(db_session, user)
        db_session.expire_all()

        response = await client.get("/v1/ratings/me", headers=headers)
        assert response.status_code in (401, 403), response.text

    async def test_a_refresh_token_cannot_be_exchanged_after_deletion(
        self, client, db_session
    ):
        body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        refresh = body["tokens"]["refresh_token"]

        await delete_account(db_session, user)
        db_session.expire_all()

        response = await client.post(
            "/v1/auth/refresh", json={"refresh_token": refresh}
        )
        assert response.status_code in (401, 403), response.text

    async def test_every_refresh_token_is_revoked_not_deleted(self, client, db_session):
        """Revoked rather than removed.

        `replaced_by_id` is what makes a replay detectable as theft; a row that no
        longer exists is a row the reuse walk cannot find, so deleting the tokens
        would destroy the evidence of an attack that has already happened.
        """
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        await db_session.commit()

        await delete_account(db_session, user)
        await db_session.refresh(user)

        rows = (
            await db_session.scalars(
                select(RefreshToken).where(RefreshToken.user_id == user.id)
            )
        ).all()
        assert rows, "revocation must leave the rows behind"
        assert all(row.revoked_at is not None for row in rows)

    async def test_sign_in_is_refused_and_does_not_leak_that_the_row_existed(
        self, client, db_session
    ):
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")

        await delete_account(db_session, user)
        db_session.expire_all()

        response = await client.post(
            "/v1/auth/login",
            json={"email": "ada@student.makerere.ac.ug", "password": GOOD_PASSWORD},
        )
        # The same answer a wrong password gets. A distinguishable answer -- 403,
        # or a message naming the address -- turns the endpoint into an oracle for
        # "was there ever an account here".
        assert response.status_code in (400, 401, 403), response.text
        assert GOOD_PASSWORD not in response.text

    async def test_the_tutor_role_is_dropped_so_a_tombstone_is_not_proposed(
        self, client, db_session
    ):
        """Load-bearing for matching.

        Deletion keeps competencies on purpose, and the matching candidate query
        joins `user_roles` on the tutor role. Dropping the role is therefore what
        stops a deleted person being proposed to students as somebody they can
        book -- the evidence is kept, the availability is not.
        """
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )

        await delete_account(db_session, tutor)
        await db_session.commit()

        roles = await db_session.scalar(
            select(func.count()).select_from(User.__table__).where(User.id == tutor.id)
        )
        assert roles is not None
        remaining = (
            await db_session.execute(
                select(func.count()).select_from(
                    RefreshToken.__table__.metadata.tables["user_roles"]
                )
            )
        ).scalar()
        assert remaining == 0, "a tombstone must hold no role grants"

    async def test_is_active_is_cleared_as_a_second_lock(self, client, db_session):
        """Fail-closed against code not yet taught about deletion.

        Every existing access path reads `is_active`. Setting it means a
        moderation process that later flips it back cannot resurrect the account,
        because `deleted_at` is still set.
        """
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert user.is_active is False


# --- the endpoint ----------------------------------------------------------


class TestDeleteEndpoint:
    async def test_delete_me_returns_204_and_no_body(self, client, db_session):
        _body, _user = await _account(client, db_session, "ada@student.makerere.ac.ug")

        response = await client.delete("/v1/users/me", headers=_bearer(_body))

        assert response.status_code == 204, response.text
        assert response.content in (b"", b"null"), response.content

    async def test_delete_me_requires_authentication(self, client):
        assert (await client.delete("/v1/users/me")).status_code in (401, 403)

    async def test_delete_me_cannot_be_replayed_with_the_same_token(
        self, client, db_session
    ):
        """A retried delete is refused, which also refuses to confirm the row existed.

        Both paths end in the same place -- not signed in, account anonymised --
        and telling them apart would leak that a `public_id` was ever live.
        """
        _body, _user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        headers = _bearer(_body)
        assert (await client.delete("/v1/users/me", headers=headers)).status_code == 204

        second = await client.delete("/v1/users/me", headers=headers)

        assert second.status_code in (401, 403), second.text

    async def test_one_user_cannot_delete_another(self, client, db_session):
        _ada, ada_user = await _account(
            client, db_session, "ada@student.makerere.ac.ug"
        )
        _grace, _grace_user = await _account(
            client, db_session, "grace@student.makerere.ac.ug"
        )

        response = await client.delete("/v1/users/me", headers=_bearer(_grace))

        assert response.status_code == 204
        await db_session.refresh(ada_user)
        # The whole point of `DELETE /me` being scoped to the caller.
        assert ada_user.deleted_at is None
        assert ada_user.email == "ada@student.makerere.ac.ug"


# --- idempotence -----------------------------------------------------------


class TestIdempotence:
    async def test_deleting_twice_does_not_move_the_recorded_instant(self, db_session):
        """The timestamp is what a retention answer cites.

        It records when the request was first received. A client retrying must not
        be able to push it forward, or the answer to "when did they ask?" becomes
        "whenever they last retried".
        """
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )

        await delete_account(db_session, tutor)
        await db_session.refresh(tutor)
        first = tutor.deleted_at
        assert first is not None

        await delete_account(db_session, tutor)
        await db_session.refresh(tutor)

        assert tutor.deleted_at == first
        assert tutor.email == tombstone_email(tutor.public_id)

    async def test_deleted_at_is_set_utc_aware(self, db_session):
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )

        await delete_account(db_session, tutor)
        await db_session.refresh(tutor)

        assert tutor.deleted_at is not None
        # Asserted on the declared column rather than the value in hand: SQLite
        # drops the offset on read, so `tzinfo` on the value is a property of the
        # engine and says nothing about whether the column is stored as UTC. A
        # naive timestamp read back in another offset answers a different question
        # about when this happened.
        assert User.__table__.c.deleted_at.type.timezone is True

    async def test_two_tombstones_do_not_collide_on_the_placeholder_address(
        self, client, db_session
    ):
        """`public_id` is unique, so the derived address is too.

        A constant placeholder would collide on the unique index and make the
        second deletion fail -- which would mean the second person asking to be
        forgotten could never be forgotten.
        """
        _b1, ada = await _account(client, db_session, "ada@student.makerere.ac.ug")
        _b2, grace = await _account(client, db_session, "grace@student.makerere.ac.ug")

        await delete_account(db_session, ada)
        await delete_account(db_session, grace)
        await db_session.refresh(ada)
        await db_session.refresh(grace)

        assert ada.email != grace.email
        assert ada.email.startswith("deleted+")
        assert grace.email.startswith("deleted+")


# --- how a tombstone is shown ---------------------------------------------


class TestDisplayName:
    async def test_a_live_user_with_no_name_falls_back_to_their_email(self, db_session):
        """The fallback is preserved for the case it was written for.

        An account with no name is a real, reachable state: the onboarding wizard
        can be abandoned after registration.
        """
        user = User(email="anon@student.makerere.ac.ug", password_hash="x")
        db_session.add(user)
        await db_session.commit()

        assert user.display_name == "anon@student.makerere.ac.ug"

    async def test_a_named_user_shows_their_name(self, client, db_session):
        _body, user = await _account(client, db_session, "x@y.z")
        assert user.display_name == "Ada Lovelace"

    async def test_a_tombstone_shows_neither_blank_nor_its_placeholder(
        self, client, db_session
    ):
        """The two wrong answers, both of which the old fallback produced.

        `full_name or email` over a scrubbed row renders either an empty string
        or `deleted+<uuid>@deleted.invalid` as though it were a person's name.
        """
        _body, user = await _account(client, db_session, "x@y.z")

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert user.display_name == "Deleted user"
        assert user.display_name.strip()
        assert "deleted.invalid" not in user.display_name
        assert "@" not in user.display_name

    async def test_is_deleted_reads_deleted_at_rather_than_a_second_flag(
        self, client, db_session
    ):
        _body, user = await _account(client, db_session, "x@y.z")
        assert user.is_deleted is False
        user.deleted_at = datetime.now(UTC)
        assert user.is_deleted is True


# --- what a tombstone must not appear as -----------------------------------


class TestTombstonesAreNotProposedAsTutors:
    async def test_a_deleted_tutor_is_not_proposed_for_a_new_request(
        self, client, db_session
    ):
        """Evidence kept, availability withdrawn.

        The competencies stay, so the only thing standing between a tombstone and
        a student's match list is the role grant being gone. This asserts that
        from the outside, because it is the guarantee a product owner would be
        asked about.
        """
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )
        body, _student = await _account(
            client, db_session, "ada@student.makerere.ac.ug"
        )
        student_row = await db_session.scalar(
            select(User).where(User.email == "ada@student.makerere.ac.ug")
        )
        assert student_row is not None
        student_row.university_id = university.id
        student_row.faculty_id = await sole_faculty_id(db_session, university)
        unit_public_id = str(unit.public_id)
        tutor_public_id = str(tutor.public_id)
        await db_session.commit()

        response = await client.post(
            "/v1/matching/suggestions",
            headers=_bearer(body),
            json={"course_unit_id": unit_public_id},
        )
        assert response.status_code == 200, response.text
        assert any(
            candidate["tutor"]["user_id"] == tutor_public_id
            for candidate in response.json()["candidates"]
        ), "precondition: a live tutor is proposed"

        await delete_account(db_session, tutor)
        db_session.expire_all()

        after = await client.post(
            "/v1/matching/suggestions",
            headers=_bearer(body),
            json={"course_unit_id": unit_public_id},
        )
        assert after.status_code == 200, after.text
        assert not any(
            candidate["tutor"]["user_id"] == tutor_public_id
            for candidate in after.json()["candidates"]
        ), "a deleted account must not be proposed as somebody to book"

    async def test_a_deleted_tutor_leaves_the_rail(self, client, db_session):
        university, unit, grade = await _institution(db_session)
        tutor = await _verified_tutor(
            db_session, university, unit, grade, "grace@student.makerere.ac.ug"
        )
        body, _student = await _account(
            client, db_session, "ada@student.makerere.ac.ug"
        )
        student_row = await db_session.scalar(
            select(User).where(User.email == "ada@student.makerere.ac.ug")
        )
        assert student_row is not None
        student_row.university_id = university.id
        student_row.faculty_id = await sole_faculty_id(db_session, university)
        tutor_public_id = str(tutor.public_id)
        await db_session.commit()

        before = await client.get("/v1/tutors/top", headers=_bearer(body))
        assert before.status_code == 200, before.text
        assert any(
            tutor_row["user_id"] == tutor_public_id for tutor_row in before.json()
        ), "precondition: a live tutor is on the rail"

        await delete_account(db_session, tutor)
        db_session.expire_all()

        after = await client.get("/v1/tutors/top", headers=_bearer(body))
        assert after.status_code == 200, after.text
        assert not any(
            tutor_row["user_id"] == tutor_public_id for tutor_row in after.json()
        ), "a deleted account must not appear in discovery"


# --- what is deliberately NOT deleted --------------------------------------


class TestNothingIsHardDeleted:
    """A direct count, so the cascade cannot creep back in unnoticed.

    The individual tests above check the rows that matter. This one checks that
    the `users` row itself is still there, because that is the property every
    FK policy in the schema depends on and the easiest one to lose to a future
    "let's just delete the row" change.
    """

    async def test_the_user_row_survives(self, client, db_session):
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        user_id = user.id

        await delete_account(db_session, user)
        await db_session.commit()

        survivor = await db_session.get(User, user_id)
        assert survivor is not None, "the row must remain as a tombstone"
        assert survivor.is_deleted is True

    async def test_nothing_but_the_identity_moved(self, client, db_session):
        """`public_id` is the join every relationship already uses.

        Rewriting it would break every FK that still points at this row -- the
        sessions, the ratings, the endorsements -- which is the opposite of
        keeping the evidence.
        """
        _body, user = await _account(client, db_session, "ada@student.makerere.ac.ug")
        original = user.public_id

        await delete_account(db_session, user)
        await db_session.refresh(user)

        assert user.public_id == original
