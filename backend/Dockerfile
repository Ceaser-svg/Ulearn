# syntax=docker/dockerfile:1

# PeerPass API image.
#
# Built from `backend/` as the context:
#
#     docker build -t peerpass-api -f Dockerfile backend
#
# Two stages on purpose. The pinned requirements are installed into a virtual
# environment in the builder, which carries a compiler; the runtime copies only
# the environment. That is the difference between an image whose attack surface
# includes a toolchain and one whose surface is the interpreter and the app.

FROM python:3.14-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Only a fallback. The pinned set publishes manylinux wheels for amd64 and arm64,
# so the normal path compiles nothing and this is never exercised -- but a
# platform without a wheel should build slowly rather than fail.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# `--require-hashes` is what makes the lockfile a claim about the artifacts, not
# only the versions. It fails the build if any wheel's hash differs from the one
# that was reviewed.
COPY requirements.txt ./
RUN pip install --require-hashes -r requirements.txt


FROM python:3.14-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# A non-root user with no home. The service needs no capability after start, and
# a container that can write to its own code is one where a remote code
# execution survives a restart.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY app ./app
COPY alembic ./alembic
COPY alembic.ini ./alembic.ini
COPY main.py ./main.py

USER app

EXPOSE 8000

# Liveness, and deliberately not readiness. It must not touch the database, for
# the same reason the `/health` route does not: a probe that fails on a database
# blip turns a blip into a restart loop. Readiness is the orchestrator's job and
# it asks `/ready`, which does check the database.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"

# Migrations are not run here on purpose. Several replicas starting together
# would race the same `alembic upgrade`; the deploy runs it as its own step
# before this image is rolled out.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
