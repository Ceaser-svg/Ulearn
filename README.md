# PeerPass

**A Peer-to-Peer Academic Support Network**

> Dismantling the "attend lectures and fight for your life" model.  
> PeerPass matches struggling university students with verified peer tutors for focused, stigma-free micro-interventions — reducing retake rates and academic drop-off.

[![Flutter](https://img.shields.io/badge/Frontend-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![FastAPI](https://img.shields.io/badge/Backend-FastAPI-009688?logo=fastapi)](https://fastapi.tiangolo.com)
[![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL-336791?logo=postgresql)](https://www.postgresql.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

---

## Overview

PeerPass is a localized, dynamic platform designed for Ugandan (and East African) universities. It connects students who need help on hyper-specific topics with peer tutors who have proven competency in those exact areas.

The platform operates on a **B2B / incentive-based model** backed by institutions or corporate sponsors. Students receive frictionless academic support; tutors earn verified Teaching Assistant certificates and leadership credits.

---

## Core Features

| Feature                            | Description                                                                                                                                                                      |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Targeted Matching Engine**       | Connects a student's specific topic request (e.g. _"Matrix Transformations"_ or _"Database Normalization"_) with a peer tutor who has verified competency in that exact area.    |
| **Multi-Tiered Validation Engine** | Ensures academic integrity through: (1) transcript grade verification (minimum B+ / A), (2) optional external portfolio proof, and (3) mandatory post-session community ratings. |
| **Incentivization Tracking**       | Automatically logs tutoring hours and generates verified Teaching Assistant certificates + leadership credits for peer tutors.                                                   |
| **Frictionless Scheduling**        | In-app coordination optimized for mobile-first, low-bandwidth environments.                                                                                                      |

---

## System Architecture

PeerPass is built as a modular, high-performance system designed for eventual integration with institutional Learning Management Systems (LMS).

| Layer        | Technology       | Purpose                                                                    |
| ------------ | ---------------- | -------------------------------------------------------------------------- |
| **Frontend** | Flutter          | Cross-platform mobile app optimized for low-bandwidth use                  |
| **Backend**  | FastAPI (Python) | Low-latency RESTful API for routing, matching logic & session management   |
| **Database** | PostgreSQL       | Relational storage for users, course units, competencies, and session logs |

For a full technical deep-dive (data model, matching engine, validation protocol, and design decisions), see:

**[Architecture Documentation](./docs/architecture.md)**

---

## Prerequisites

Ensure the following tools are installed on your local development environment:

- [Flutter SDK](https://docs.flutter.dev/install/manual) (latest stable)
- [Python 3.10+](https://www.python.org/downloads/)
- [PostgreSQL](https://www.postgresql.org/download/) (or use the container method below)
- [Git](https://github.com/git-guides/install-git)

---

## Local Development Setup

### 1. Database (Podman or Docker)

```bash
podman run --name p2p-postgres \
  -e POSTGRES_USER=admin \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=PeerPass \
  -p 5432:5432 \
  -d postgres:latest
```

### 2. Backend (FastAPI)

```bash
cd backend
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r requirements.txt

# Apply migrations and start the server
alembic upgrade head
python -m app.db.seed
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

The seed command is idempotent and loads the v1 reference catalogue, including
Mbarara University of Science and Technology, its faculties, grades, and course
units. Additional universities can be added to the backend seed data without
changing the Flutter client.

The current six-unit MUST pilot candidate list is documented in
[docs/MUST_Pilot_Catalogue.md](./docs/MUST_Pilot_Catalogue.md). It is
provisional until MUST confirms the launch units and tutor cohort.

> API documentation is available at [http://localhost:8000/docs](http://localhost:8000/docs)

### 3. Frontend (Flutter)

```bash
cd frontend
flutter pub get
flutter run
```

To run the student client in a browser against the local API, set the backend
origin explicitly before starting or restarting Uvicorn:

```bash
# Run from backend/
export CORS_ORIGINS=http://localhost:8080
uvicorn main:app --host 0.0.0.0 --port 8000 --reload

# In another terminal, from frontend/
flutter run -d chrome --web-port 8080 \
  --dart-define=API_BASE_URL=http://localhost:8000
```

Use the exact origin shown in the browser address bar. If Flutter chooses a
different port, or the address is `http://127.0.0.1:<port>`, update
`CORS_ORIGINS` to that exact scheme, host, and port. CORS settings are read at
backend startup, so restart the backend after changing them.

### 4. Admin web application

The MUST operations console is a separate Flutter web application and is not
part of the student mobile client:

```bash
cd admin_web
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

Only provisioned backend administrators can sign in. See
[admin_web/README.md](./admin_web/README.md) for the production build
configuration and the current pilot surface.

---

## Regulatory Compliance

PeerPass is engineered for institutional deployment and adheres to:

- **Uganda Data Protection and Privacy Act, 2019 (DPPA)** — Explicit consent, secure storage, and registration requirements for handling sensitive academic data (transcripts & grades)
- **Electronic Transactions Act, 2011** — Intermediary liability protections
- **Institutional IT Policies** — Network security compliance when querying student portals or integrating SSO

---

## Pilot Implementation Roadmap

The project is structured for a focused deployment cycle:

1. **Phase 1 – Pre-Pilot**  
   Legal & institutional alignment, faculty buy-in, and initial tutor vetting (10–20 tutors)

2. **Phase 2 – Closed Beta ("Sandbox")**  
   Launch to a single high-failure-rate course unit (e.g. Computer Science – Database Programming)

3. **Phase 3 – Controlled Rollout**  
   Expand to 3–5 courses across different faculties

4. **Phase 4 – Post-Pilot Evaluation**  
   Aggregate session logs, tutor ratings, and impact on continuous assessment scores for official adoption discussions

---

## Documentation

| Document                                   | Description                                                              |
| ------------------------------------------ | ------------------------------------------------------------------------ |
| **[Architecture](./docs/architecture.md)** | System design, data model, matching engine & validation protocol         |
| **[Contributing](./docs/Contribution.md)** | Code of Conduct, development workflow, coding standards & review process |

---

## Contributing

We welcome contributions of all kinds — code, documentation, testing, and ideas.

Please read **[Contribution Guide](./docs/Contribution.md)** before submitting any pull request.  
It contains our full Code of Conduct, development workflow, coding standards, and review process.

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](./LICENSE) file for details.

---

## Inquiries & Collaboration

- **Maintainer**: [Gilbert Asiimwe](https://github.com/asiimwe-dev)
- **Email**: [gilbert.asiimwe.dev@gmail.com](mailto:gilbert.asiimwe.dev@gmail.com)

For critical issues or partnership discussions, please reach out directly.

---

**Built to help students stop struggling in silence.**
