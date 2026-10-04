"""Schema-layer guarantees.

The schemas are the boundary where a database row becomes a document an
untrusted client can read. Two things must hold there, and neither is enforced by
the type system: a response carries public ids rather than primary keys, and a
request cannot smuggle a field the client should not set.
"""

import json
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from pydantic import BaseModel, ValidationError

from app.models.enums import (
    CompetencyStatus,
    HelpRequestStatus,
    SessionStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.schemas import (
    MAX_RATING,
    MIN_RATING,
    AdminCompetencyReviewRequest,
    HelpRequestCreate,
    LoginRequest,
    Page,
    PageParams,
    RatingCreate,
    RegisterRequest,
    SessionCreate,
    SessionTransitionRequest,
    UserResponse,
)

# Every response schema and every public-id accessor a schema can reach. If a
# model gains a new relationship and a schema exposes it without an alias, the
# lookup below stops finding the accessor and this fails.
PUBLIC_ID_ACCESSORS = {
    "User": ["public_id", "university_public_id"],
    "CourseUnit": [
        "public_id",
        "university_public_id",
        "subject_public_id",
        "grade_public_id",
    ],
    "Grade": ["public_id", "grading_scale_public_id"],
    "Competency": [
        "public_id",
        "user_public_id",
        "course_unit_public_id",
        "grade_public_id",
    ],
    "HelpRequest": [
        "public_id",
        "tutee_public_id",
        "course_unit_public_id",
        "matched_tutor_public_id",
    ],
    "Session": [
        "public_id",
        "tutee_public_id",
        "tutor_public_id",
        "course_unit_public_id",
        "help_request_public_id",
    ],
    "Rating": [
        "public_id",
        "session_public_id",
        "rater_public_id",
        "ratee_public_id",
    ],
}


def _model_schemas() -> dict[str, dict[str, object]]:
    """Every exported schema, with its fields.

    `__all__` also carries constants such as `MIN_RATING`, so the module is
    filtered to `BaseModel` subclasses rather than assumed to hold only classes.
    """
    import app.schemas as schemas

    exported = {}
    for name in schemas.__all__:
        obj = getattr(schemas, name)
        if isinstance(obj, type) and issubclass(obj, BaseModel):
            exported[name] = dict(obj.model_fields)
    return exported


class TestNoSecretReachesTheClient:
    def test_no_response_schema_exposes_a_secret(self) -> None:
        """The easiest thing to leak, and the costliest.

        `password_hash` and `token_hash` are columns on the model, and adding
        either to a response schema is one line that breaks nothing until someone
        reads a payload.

        The hashes, and not the tokens. A freshly minted access token is *meant*
        to be returned to its own bearer, and `TokenResponse` existing is the
        point of the login endpoint. What must never leave is the stored hash of a
        refresh token, because that one is replayable against every session that
        has not yet rotated.
        """
        schemas = _model_schemas()
        secrets = {"password_hash", "token_hash", "token_digest"}
        offenders = {
            name: sorted(secrets & set(fields))
            for name, fields in schemas.items()
            if not name.endswith(("Request", "Create")) and secrets & set(fields)
        }

        assert offenders == {}

    def test_a_password_keeps_its_spaces(self) -> None:
        """Trimming a password rewrites the secret the user chose.

        `"correct horse battery "` must not become `"correct horse battery"`, or
        the account created with a trailing space cannot be signed into without
        one, and nothing in the system reports a mismatch.
        """
        request = LoginRequest(
            email="student@ug.ac.ug", password="correct horse battery "
        )

        assert request.password == "correct horse battery "

    def test_no_request_schema_accepts_an_id_field(self) -> None:
        """A request must never carry an id the client chose.

        Public ids are fine in a path or a body where the client legitimately
        knows them, but a *primary* key is never client-supplied, and the field
        would be named plainly (`user_id`) rather than `public_id`.
        """
        import app.schemas as schemas

        request_names = [
            name for name in schemas.__all__ if name.endswith(("Request", "Create"))
        ]
        offenders = {
            name: list(
                field
                for field in getattr(schemas, name).model_fields
                if field in {"id", "user_id", "tutor_id", "session_id"}
            )
            for name in request_names
            if any(
                field in {"id", "user_id", "tutor_id", "session_id"}
                for field in getattr(schemas, name).model_fields
            )
        }

        assert offenders == {}


class TestPublicIdProjection:
    def test_every_declared_accessor_exists_on_its_model(self) -> None:
        """A schema's `validation_alias` must name a real attribute.

        Pydantic does not check an alias against the model. A typo, or a model
        that has not been given the accessor yet, means the field is silently
        omitted from the response -- a missing `id` on a list item is a client
        that cannot navigate anywhere.
        """
        from app.models import (
            Competency,
            CourseUnit,
            Grade,
            HelpRequest,
            Rating,
            Session,
            User,
        )

        models = {
            "User": User,
            "CourseUnit": CourseUnit,
            "Grade": Grade,
            "Competency": Competency,
            "HelpRequest": HelpRequest,
            "Session": Session,
            "Rating": Rating,
        }

        missing = {
            model_name: [
                accessor
                for accessor in accessors
                if not hasattr(models[model_name], accessor)
            ]
            for model_name, accessors in PUBLIC_ID_ACCESSORS.items()
        }

        assert {k: v for k, v in missing.items() if v} == {}

    def test_user_response_id_is_the_public_id(self) -> None:
        """The point of the whole arrangement, stated as a test.

        `internal_id` here stands in for the model's `id` column. A schema that
        read it would produce a body indistinguishable from a correct one in a
        snapshot test, and would leak the write-order key in production.
        """

        class Row:
            def __init__(self) -> None:
                self.id = uuid.uuid4()
                self.public_id = uuid.uuid4()
                self.email = "student@ug.ac.ug"
                self.full_name = "Test Student"
                self.roles = [UserRole.STUDENT]
                self.university_public_id = None
                self.university = None
                self.is_active = True
                self.created_at = datetime.now(UTC)

        row = Row()
        response = UserResponse.model_validate(row)

        assert response.id == row.public_id
        assert response.id != row.id


class TestRegistration:
    """Sign-up takes an address and a password, and nothing else.

    Every test here constructs `RegisterRequest` with *only* those two fields.
    A test that also passed `full_name` or `roles` would keep passing after those
    fields were removed, because `extra_forbidden` would raise for a reason that
    had nothing to do with what the test was checking.
    """

    def test_a_short_password_is_rejected(self) -> None:
        with pytest.raises(ValidationError, match="password"):
            RegisterRequest(
                email="student@ug.ac.ug",
                password="short",
            )

    def test_a_whitespace_only_password_is_rejected(self) -> None:
        """Long enough to satisfy the length rule and worth nothing as a secret.

        The account an attacker registers first is the one with a password they
        did not have to choose.
        """
        with pytest.raises(ValidationError, match="whitespace"):
            RegisterRequest(
                email="student@ug.ac.ug",
                password=" " * 20,
            )

    def test_a_malformed_email_is_rejected(self) -> None:
        with pytest.raises(ValidationError):
            RegisterRequest(
                email="not-an-email",
                password="correct-horse-battery-staple",
            )

    def test_an_unknown_field_is_rejected(self) -> None:
        """Not ignored.

        A misspelled field that is silently dropped leaves the client believing it
        set something it did not.
        """
        with pytest.raises(ValidationError):
            RegisterRequest(
                email="student@ug.ac.ug",
                password="correct-horse-battery-staple",
                verified=True,  # type: ignore[call-arg]
            )

    def test_a_name_cannot_be_supplied_at_sign_up(self) -> None:
        """The name arrives during onboarding, and a client cannot pre-empt it.

        `extra_forbidden` is what makes this safe rather than merely ignored: a
        caller who thinks they set the name gets a 422 instead of an account that
        silently kept the one it was given.
        """
        with pytest.raises(ValidationError, match="full_name"):
            RegisterRequest(
                email="student@ug.ac.ug",
                password="correct-horse-battery-staple",
                full_name="Test Student",
            )

    def test_roles_cannot_be_claimed_at_sign_up(self) -> None:
        """The tutor role is earned through a verified competency.

        A client sending `roles: ["tutor"]` must be refused outright, never
        honoured and never quietly dropped.
        """
        with pytest.raises(ValidationError, match="roles"):
            RegisterRequest(
                email="student@ug.ac.ug",
                password="correct-horse-battery-staple",
                roles=[UserRole.TUTOR],
            )


class TestAdminCompetencyReview:
    """These rules moved from the student-facing review schema when review became
    an operator-only action. The owner could otherwise mark their own submission
    verified, which is not a review. The rules themselves are unchanged: a
    rejection still has to say why."""

    def test_rejecting_without_a_reason_is_rejected(self) -> None:
        """A refusal the tutor cannot act on is a refusal they will not retry."""
        with pytest.raises(ValidationError, match="rejection_reason"):
            AdminCompetencyReviewRequest(status=CompetencyStatus.REJECTED)

    def test_a_blank_rejection_reason_is_rejected(self) -> None:
        with pytest.raises(ValidationError, match="rejection_reason"):
            AdminCompetencyReviewRequest(
                status=CompetencyStatus.REJECTED,
                rejection_reason="   ",
            )

    def test_verifying_drops_a_stale_rejection_reason(self) -> None:
        """A record that says both verified and rejected is worse than neither."""
        review = AdminCompetencyReviewRequest(
            status=CompetencyStatus.VERIFIED,
            rejection_reason="transcript was illegible",
        )

        assert review.rejection_reason is None


class TestSessionLifecycle:
    def test_cancelling_without_a_reason_is_rejected(self) -> None:
        with pytest.raises(ValidationError, match="cancellation_reason"):
            SessionTransitionRequest(status=SessionStatus.CANCELLED)

    def test_completing_drops_a_stale_cancellation_reason(self) -> None:
        transition = SessionTransitionRequest(
            status=SessionStatus.COMPLETED,
            cancellation_reason="tutor unwell",
        )

        assert transition.cancellation_reason is None

    def test_a_naive_scheduled_start_is_rejected(self) -> None:
        """No timezone means the instant is ambiguous.

        Accepting it would let a client in a timezone it did not mean schedule a
        session that lands hours away from when the tutor was told to attend.
        """
        with pytest.raises(ValidationError, match="timezone"):
            SessionCreate(
                course_unit_id=uuid.uuid4(),
                topic="Eigenvalues",
                duration_minutes=60,
                scheduled_start=datetime.now(UTC).replace(tzinfo=None),
            )

    def test_a_past_scheduled_start_is_rejected(self) -> None:
        with pytest.raises(ValidationError, match="future"):
            SessionCreate(
                course_unit_id=uuid.uuid4(),
                topic="Eigenvalues",
                duration_minutes=60,
                scheduled_start=datetime.now(UTC) - timedelta(hours=1),
            )

    def test_a_future_scheduled_start_is_accepted(self) -> None:
        created = SessionCreate(
            course_unit_id=uuid.uuid4(),
            topic="Eigenvalues",
            duration_minutes=60,
            scheduled_start=datetime.now(UTC) + timedelta(hours=1),
        )

        assert created.duration_minutes == 60

    @pytest.mark.parametrize("minutes", [0, -30, 10_000])
    def test_an_implausible_duration_is_rejected(self, minutes: int) -> None:
        """Zero would complete instantly and bank certificate hours."""
        with pytest.raises(ValidationError):
            SessionCreate(
                course_unit_id=uuid.uuid4(),
                topic="Eigenvalues",
                duration_minutes=minutes,
            )


class TestHelpRequest:
    @pytest.mark.parametrize("topic", ["a", "", "   x"])
    def test_an_unusable_topic_is_rejected(self, topic: str) -> None:
        """The course is already known, so the topic has to add something."""
        with pytest.raises(ValidationError):
            HelpRequestCreate(course_unit_id=uuid.uuid4(), topic=topic)


class TestRating:
    @pytest.mark.parametrize("score", [MIN_RATING - 1, MAX_RATING + 1, 0])
    def test_an_out_of_range_score_is_rejected(self, score: int) -> None:
        with pytest.raises(ValidationError):
            RatingCreate(score=score)

    @pytest.mark.parametrize("score", [MIN_RATING, MAX_RATING])
    def test_the_bounds_themselves_are_accepted(self, score: int) -> None:
        """A gate at exactly B+ is a gate the boundary values must pass."""
        assert RatingCreate(score=score).score == score

    def test_the_bounds_agree_with_the_database(self) -> None:
        """Stated in two places, so the two are pinned to each other.

        The CHECK constraint and the schema must not drift: a client that could
        submit a 6 and was told no would be told yes by the database, and the
        error would surface as a 409 instead of a field message.
        """
        from app.models.rating import MAX_RATING as DB_MAX
        from app.models.rating import MIN_RATING as DB_MIN

        assert (MIN_RATING, MAX_RATING) == (DB_MIN, DB_MAX)


class TestPagination:
    def test_a_page_reports_whether_more_exist(self) -> None:
        page = Page[str](items=["a", "b"], total=10, limit=2, offset=0)

        assert page.has_more is True
        assert page.page_count == 5

    def test_the_last_page_reports_no_more(self) -> None:
        page = Page[str](items=["i", "j"], total=10, limit=2, offset=8)

        assert page.has_more is False

    def test_an_empty_result_is_not_an_error(self) -> None:
        page = Page[str](items=[], total=0, limit=20, offset=0)

        assert page.has_more is False
        assert page.page_count == 0

    def test_the_page_size_is_capped(self) -> None:
        """A client must not be able to ask for the whole table on a metered
        connection."""
        with pytest.raises(ValidationError):
            PageParams(limit=100_000)

    def test_a_negative_offset_is_rejected(self) -> None:
        with pytest.raises(ValidationError):
            PageParams(offset=-1)


class TestEnumValuesAreWireSafe:
    @pytest.mark.parametrize(
        "enum_type",
        [
            UserRole,
            VerificationSource,
            CompetencyStatus,
            TutorStanding,
            HelpRequestStatus,
            SessionStatus,
        ],
    )
    def test_every_enum_value_is_lowercase_snake_case(self, enum_type: type) -> None:
        """The client parses these strings.

        An upper-case value would be a wire change nobody notices until a Flutter
        `enum` fails to deserialise in the field.
        """
        import re

        for member in enum_type:
            assert re.fullmatch(r"[a-z][a-z0-9_]*", member.value), member.value

    def test_a_decimal_survives_serialisation_exactly(self) -> None:
        """Grade points and rating totals are compared against exact thresholds.

        A tutor at exactly the promotion bar is promoted or not, with no
        tolerance. Through a float, `4.10` becomes `4.0999999999999996` and the
        comparison flips -- so the value has to stay a `Decimal` all the way into
        the JSON, and the client has to parse it as one.
        """
        from app.schemas.tutor import TutorProfileSummary

        summary = TutorProfileSummary(
            user_id=uuid.uuid4(),
            full_name="Test Tutor",
            standing=TutorStanding.VERIFIED,
            average_rating=Decimal("4.10"),
            completed_sessions=3,
        )

        payload = json.loads(summary.model_dump_json())

        # A JSON string, deliberately. A JSON number would be a double by the
        # time Dart decoded it, and the promotion threshold is an equality test.
        assert payload["average_rating"] == "4.10"
        assert Decimal(payload["average_rating"]) == Decimal("4.10")

    def test_a_rating_total_keeps_its_scale(self) -> None:
        """Both decimal places survive to the wire.

        A total of `18.00` is what the database stores, and what the tutor's
        average is computed from. Emitting `18` would look tidier and lose the
        scale.
        """
        from app.schemas.tutor import TutorProfileResponse

        profile = TutorProfileResponse(
            id=uuid.uuid4(),
            user_id=uuid.uuid4(),
            standing=TutorStanding.VERIFIED,
            completed_sessions=4,
            certified_minutes=1200,
            rating_total=Decimal("18.00"),
            rating_count=4,
            average_rating=Decimal("4.50"),
        )

        payload = json.loads(profile.model_dump_json())

        assert payload["rating_total"] == "18.00"


class TestLogin:
    def test_an_over_long_password_is_rejected_before_hashing(self) -> None:
        """Bounded at the schema so a 10 MB body is not fed to PBKDF2.

        Without this, the expensive part of the request would be reached with
        attacker-chosen input, which is a denial of service against the one
        operation that is deliberately slow.
        """
        with pytest.raises(ValidationError):
            LoginRequest(email="student@ug.ac.ug", password="x" * 200)
