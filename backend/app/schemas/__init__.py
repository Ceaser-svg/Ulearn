"""Pydantic transport types.

Request bodies and response bodies. No business rules live here: a schema
validates shape, and the services in `app.services` decide meaning. The one
exception is a cross-field rule that has no other natural home -- a rejection
without a reason, say -- and each of those says so where it is enforced.
"""

from app.schemas.academic import (
    CourseUnitResponse,
    GradeResponse,
    GradingScaleResponse,
    SubjectResponse,
    UniversityResponse,
)
from app.schemas.admin import (
    AdminAuditEventPage,
    AdminAuditEventResponse,
    AdminCompetencyReviewRequest,
    AdminUserPage,
    AdminUserResponse,
)
from app.schemas.base import OrmSchema, RequestSchema
from app.schemas.common import (
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
    MessageResponse,
    Page,
    PageParams,
)
from app.schemas.competency import (
    CompetencyCreate,
    CompetencyResponse,
)
from app.schemas.matching import (
    MATCH_EXCLUSION_REASONS,
    MatchCandidate,
    MatchExclusion,
    MatchRequest,
    MatchResponse,
)
from app.schemas.rating import (
    MAX_RATING,
    MIN_RATING,
    RatingCreate,
    RatingResponse,
    TutorRatingSummary,
)
from app.schemas.session import (
    HelpRequestCreate,
    HelpRequestResponse,
    SessionCreate,
    SessionResponse,
    SessionTransitionRequest,
)
from app.schemas.tutor import (
    DEFAULT_RAIL_TUTORS,
    MAX_RAIL_TUTORS,
    RAIL_ENDORSED_UNITS,
    CertificateEligibilityResponse,
    TutorDetailResponse,
    TutorProfileResponse,
    TutorProfileSummary,
    TutorRailEntry,
)
from app.schemas.user import (
    AuthResponse,
    CurrentUserResponse,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
    UserResponse,
)

__all__ = [
    "DEFAULT_PAGE_SIZE",
    "DEFAULT_RAIL_TUTORS",
    "MATCH_EXCLUSION_REASONS",
    "MAX_PAGE_SIZE",
    "MAX_RAIL_TUTORS",
    "MAX_RATING",
    "MIN_RATING",
    "RAIL_ENDORSED_UNITS",
    "AdminAuditEventPage",
    "AdminAuditEventResponse",
    "AdminCompetencyReviewRequest",
    "AdminUserPage",
    "AdminUserResponse",
    "AuthResponse",
    "CertificateEligibilityResponse",
    "CompetencyCreate",
    "CompetencyResponse",
    "CourseUnitResponse",
    "CurrentUserResponse",
    "GradeResponse",
    "GradingScaleResponse",
    "HelpRequestCreate",
    "HelpRequestResponse",
    "LoginRequest",
    "MatchCandidate",
    "MatchExclusion",
    "MatchRequest",
    "MatchResponse",
    "MessageResponse",
    "OrmSchema",
    "Page",
    "PageParams",
    "RatingCreate",
    "RatingResponse",
    "RefreshRequest",
    "RegisterRequest",
    "RequestSchema",
    "SessionCreate",
    "SessionResponse",
    "SessionTransitionRequest",
    "SubjectResponse",
    "TokenResponse",
    "TutorDetailResponse",
    "TutorProfileResponse",
    "TutorProfileSummary",
    "TutorRailEntry",
    "TutorRatingSummary",
    "UniversityResponse",
    "UserResponse",
]
