"""SQLAlchemy persistence models.

Every model is imported here so that Alembic's autogenerate and the test
fixture's `create_all` see the complete metadata. A model that is not reachable
from this module does not exist as far as migrations are concerned, and the
resulting "missing table" surfaces at runtime rather than at review.
"""

from app.core.database import Base
from app.models.audit import AdminAuditEvent
from app.models.base import TimestampMixin, enum_column, public_id_column
from app.models.competency import Competency
from app.models.course_unit import CourseUnit, Program, Subject, University
from app.models.endorsement import UnitEndorsement
from app.models.enums import (
    COMPLETED_SESSION_STATUSES,
    SESSION_TRANSITIONS,
    CompetencyStatus,
    HelpRequestStatus,
    SessionStatus,
    TutorStanding,
    UserRole,
    VerificationSource,
)
from app.models.grading_scale import Grade, GradingScale
from app.models.rate_limit import RateLimitCounter
from app.models.rating import MAX_RATING, MIN_RATING, Rating
from app.models.session import HelpRequest, Session
from app.models.tutor_profile import TutorProfile
from app.models.user import (
    RefreshToken,
    User,
    has_role,
    load_roles,
    set_roles,
    user_roles,
)

__all__ = [
    "COMPLETED_SESSION_STATUSES",
    "MAX_RATING",
    "MIN_RATING",
    "SESSION_TRANSITIONS",
    "AdminAuditEvent",
    "Base",
    "Competency",
    "CompetencyStatus",
    "CourseUnit",
    "Grade",
    "GradingScale",
    "HelpRequest",
    "HelpRequestStatus",
    "Program",
    "RateLimitCounter",
    "Rating",
    "RefreshToken",
    "Session",
    "SessionStatus",
    "Subject",
    "TimestampMixin",
    "TutorProfile",
    "TutorStanding",
    "UnitEndorsement",
    "University",
    "User",
    "UserRole",
    "VerificationSource",
    "enum_column",
    "has_role",
    "load_roles",
    "public_id_column",
    "set_roles",
    "user_roles",
]
