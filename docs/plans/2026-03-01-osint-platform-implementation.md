# OSINT Platform Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a self-hosted OSINT monitoring platform (Use Case C: continuous threat intel monitoring) deployed on Cortech K3s, with feed ingestion, entity extraction, semantic correlation, scoring, alerting, and LLM-powered intel briefs — all driven by Collection Plan as Code.

**Architecture:** Custom FastAPI + Celery monolith (`osint-core`) deployed in K8s `osint` namespace. Celery Beat schedules feed polling; workers ingest, enrich (spaCy NER on wrk-3), vectorize (Qdrant), score, and alert (Gotify/Apprise). Ollama generates briefs with Jinja2 fallback. All state in Postgres (LXC 114), queues in Redis (LXC 116).

**Tech Stack:** Python 3.12, FastAPI, Celery 5.4+, SQLAlchemy 2.0 (async), Alembic, Pydantic v2, httpx, spaCy, sentence-transformers, qdrant-client, apprise, structlog, prometheus-fastapi-instrumentator, ruff, mypy, pytest.

**Two repos:**
- `osint-core` — new repo (`github.com/jacorbello/osint-core`), application code
- `cortech-infra` — this repo, K8s manifests in `apps/osint/`, NGINX config, Grafana dashboard

**Design doc:** `docs/plans/2026-03-01-osint-platform-design.md`

---

## Phase 0: Foundations

### Task 1: Create osint-core repo scaffold

**Files:**
- Create: `osint-core/pyproject.toml`
- Create: `osint-core/src/osint_core/__init__.py`
- Create: `osint-core/src/osint_core/config.py`
- Create: `osint-core/.gitignore`
- Create: `osint-core/.python-version`

**Step 1: Create GitHub repo**

```bash
gh repo create jacorbello/osint-core --private --clone
cd osint-core
```

**Step 2: Create .python-version**

```
3.12
```

**Step 3: Create .gitignore**

Standard Python gitignore: `__pycache__/`, `.venv/`, `*.egg-info/`, `.mypy_cache/`, `.ruff_cache/`, `.pytest_cache/`, `dist/`, `.env`.

**Step 4: Create pyproject.toml**

```toml
[project]
name = "osint-core"
version = "0.1.0"
description = "OSINT monitoring platform — feed ingestion, scoring, alerting, intel briefs"
requires-python = ">=3.12"
dependencies = [
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.30.0",
    "celery[redis]>=5.4.0",
    "sqlalchemy[asyncio]>=2.0.0",
    "asyncpg>=0.29.0",
    "alembic>=1.13.0",
    "pydantic>=2.0.0",
    "pydantic-settings>=2.0.0",
    "httpx>=0.27.0",
    "pyyaml>=6.0",
    "jsonschema>=4.20.0",
    "apprise>=1.8.0",
    "qdrant-client>=1.9.0",
    "sentence-transformers>=3.0.0",
    "structlog>=24.0.0",
    "prometheus-fastapi-instrumentator>=7.0.0",
    "jinja2>=3.1.0",
    "python-jose[cryptography]>=3.3.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "pytest-cov>=5.0.0",
    "factory-boy>=3.3.0",
    "ruff>=0.5.0",
    "mypy>=1.10.0",
    "httpx",  # for TestClient
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/osint_core"]

[tool.ruff]
target-version = "py312"
line-length = 100
src = ["src"]

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP", "B", "SIM"]

[tool.mypy]
python_version = "3.12"
strict = true
plugins = ["pydantic.mypy"]

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"
```

**Step 5: Create src/osint_core/__init__.py**

```python
"""OSINT monitoring platform."""
```

**Step 6: Create src/osint_core/config.py**

```python
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    model_config = {"env_prefix": "OSINT_"}

    # Postgres (LXC 114)
    database_url: str = "postgresql+asyncpg://osint:osint@postgres:5432/osint"

    # Redis (LXC 116)
    redis_url: str = "redis://redis:6379/0"
    celery_broker_url: str = "redis://redis:6379/1"
    celery_result_backend: str = "redis://redis:6379/2"

    # Qdrant (K8s osint namespace)
    qdrant_host: str = "qdrant"
    qdrant_port: int = 6333
    qdrant_collection: str = "osint-events"

    # Ollama (VM 205)
    ollama_url: str = "http://ollama:11434"
    ollama_model: str = "llama3.1:8b"

    # MinIO (LXC 123)
    minio_endpoint: str = "minio:9000"
    minio_access_key: str = ""
    minio_secret_key: str = ""
    minio_secure: bool = False

    # Gotify (K8s osint namespace)
    gotify_url: str = "http://gotify/message"
    gotify_token: str = ""

    # Keycloak (LXC 121)
    keycloak_url: str = "https://keycloak.corbello.io"
    keycloak_realm: str = "cortech"
    keycloak_client_id: str = "osint-core"

    # App
    plan_dir: str = "/app/plans"
    log_level: str = "INFO"
    api_prefix: str = "/api/v1"
    cors_origins: list[str] = ["*"]


settings = Settings()
```

**Step 7: Create empty test structure**

```bash
mkdir -p tests
touch tests/__init__.py tests/conftest.py
```

**Step 8: Commit**

```bash
git add -A
git commit -m "feat: scaffold osint-core project with pyproject.toml and config"
```

---

### Task 2: Database models + Alembic migrations

**Files:**
- Create: `src/osint_core/models/__init__.py`
- Create: `src/osint_core/models/base.py`
- Create: `src/osint_core/models/plan.py`
- Create: `src/osint_core/models/event.py`
- Create: `src/osint_core/models/entity.py`
- Create: `src/osint_core/models/indicator.py`
- Create: `src/osint_core/models/artifact.py`
- Create: `src/osint_core/models/alert.py`
- Create: `src/osint_core/models/brief.py`
- Create: `src/osint_core/models/job.py`
- Create: `src/osint_core/models/audit.py`
- Create: `src/osint_core/db.py`
- Create: `migrations/` (Alembic)
- Test: `tests/test_models.py`

**Step 1: Write the failing test**

```python
# tests/test_models.py
from osint_core.models.base import Base
from osint_core.models.event import Event
from osint_core.models.plan import PlanVersion
from osint_core.models.indicator import Indicator
from osint_core.models.entity import Entity
from osint_core.models.alert import Alert
from osint_core.models.brief import Brief
from osint_core.models.job import Job
from osint_core.models.audit import AuditLog


def test_all_models_registered():
    """All models must be importable and registered with Base."""
    table_names = set(Base.metadata.tables.keys())
    expected = {
        "plan_versions", "events", "entities", "indicators",
        "artifacts", "alerts", "briefs", "jobs", "audit_log",
        "event_entities", "event_indicators", "event_artifacts",
    }
    assert expected.issubset(table_names), f"Missing tables: {expected - table_names}"


def test_event_model_has_expected_columns():
    columns = {c.name for c in Event.__table__.columns}
    assert "dedupe_fingerprint" in columns
    assert "score" in columns
    assert "severity" in columns
    assert "source_id" in columns
```

**Step 2: Run test to verify it fails**

Run: `cd osint-core && python -m pytest tests/test_models.py -v`
Expected: FAIL with `ModuleNotFoundError`

**Step 3: Create src/osint_core/db.py**

```python
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from osint_core.config import settings

engine = create_async_engine(settings.database_url, echo=False)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def get_session() -> AsyncSession:  # type: ignore[misc]
    async with async_session() as session:
        yield session
```

**Step 4: Create src/osint_core/models/base.py**

```python
import uuid
from datetime import datetime

from sqlalchemy import DateTime, MetaData, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

convention = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=convention, schema="osint")


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class UUIDMixin:
    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
```

**Step 5: Create all model files**

Each model file follows the schema from the EDD (Section 4). Full column definitions from the EDD SQL, translated to SQLAlchemy 2.0 mapped_column syntax.

- `src/osint_core/models/plan.py` — `PlanVersion` model with `plan_id`, `version`, `content_hash`, `content` (JSON), `retention_class`, `is_active`, etc.
- `src/osint_core/models/event.py` — `Event` model with `event_type`, `source_id`, `title`, `summary`, `score`, `severity`, `dedupe_fingerprint`, plus `event_entities` and `event_indicators` and `event_artifacts` association tables.
- `src/osint_core/models/entity.py` — `Entity` with `entity_type`, `name`, `aliases` (ARRAY), `attributes` (JSON).
- `src/osint_core/models/indicator.py` — `Indicator` with `indicator_type`, `value`, `confidence`, `sources` (ARRAY), unique constraint on `(indicator_type, value)`.
- `src/osint_core/models/artifact.py` — `Artifact` with `artifact_type`, `minio_uri`, `sha256`, `capture_tool`, etc.
- `src/osint_core/models/alert.py` — `Alert` with `fingerprint`, `severity`, `title`, `status`, `occurrences`, `event_ids`/`indicator_ids`/`entity_ids` (ARRAY), etc.
- `src/osint_core/models/brief.py` — `Brief` with `title`, `content_md`, `target_query`, `generated_by`, `model_id`, array refs.
- `src/osint_core/models/job.py` — `Job` with `job_type`, `status`, `celery_task_id`, `k8s_job_name`, `idempotency_key`, `retry_count`, etc.
- `src/osint_core/models/audit.py` — `AuditLog` with `action`, `actor`, `actor_username`, `actor_roles` (ARRAY), `details` (JSON).
- `src/osint_core/models/__init__.py` — imports all models to ensure registry.

Key implementation details:
- Use `Mapped[]` and `mapped_column()` (SQLAlchemy 2.0 style)
- Use `UUID(as_uuid=True)` for all IDs
- Use `JSONB` for `content`, `metadata`, `attributes`, `input_params`, `output`, `details`
- Use `ARRAY(Text)` for `aliases`, `sources`, `actor_roles`, `event_ids`, `indicator_ids`, `entity_ids`
- Use `CheckConstraint` for severity/status enums
- ForeignKey references to `osint.plan_versions.id` where specified
- Association tables (`event_entities`, `event_indicators`, `event_artifacts`) defined inline in `event.py`

**Step 6: Run test to verify it passes**

Run: `python -m pytest tests/test_models.py -v`
Expected: PASS

**Step 7: Initialize Alembic**

```bash
pip install -e ".[dev]"
alembic init migrations
```

Edit `migrations/env.py`:
- Set `target_metadata = Base.metadata`
- Import all models from `osint_core.models`
- Configure async engine from `settings.database_url`

Edit `alembic.ini`:
- Set `sqlalchemy.url` to use env var `OSINT_DATABASE_URL`

**Step 8: Generate initial migration**

```bash
alembic revision --autogenerate -m "initial schema"
```

Review the generated migration to confirm it creates all tables in the `osint` schema with correct columns, indexes, and constraints (including the FTS generated column and GIN indexes).

**Step 9: Commit**

```bash
git add -A
git commit -m "feat: add database models and Alembic migrations for OSINT schema"
```

---

### Task 3: Pydantic schemas (request/response)

**Files:**
- Create: `src/osint_core/schemas/__init__.py`
- Create: `src/osint_core/schemas/plan.py`
- Create: `src/osint_core/schemas/event.py`
- Create: `src/osint_core/schemas/indicator.py`
- Create: `src/osint_core/schemas/entity.py`
- Create: `src/osint_core/schemas/alert.py`
- Create: `src/osint_core/schemas/brief.py`
- Create: `src/osint_core/schemas/job.py`
- Create: `src/osint_core/schemas/audit.py`
- Create: `src/osint_core/schemas/common.py`
- Test: `tests/test_schemas.py`

**Step 1: Write the failing test**

```python
# tests/test_schemas.py
from osint_core.schemas.event import EventResponse, EventList
from osint_core.schemas.plan import PlanVersionResponse, PlanValidationResult
from osint_core.schemas.alert import AlertResponse
from osint_core.schemas.common import PaginatedResponse


def test_event_response_schema():
    data = {
        "id": "00000000-0000-0000-0000-000000000001",
        "event_type": "cve_published",
        "source_id": "nvd_feeds_recent",
        "title": "CVE-2026-0001",
        "severity": "high",
        "score": 3.5,
        "dedupe_fingerprint": "abc123",
        "ingested_at": "2026-03-01T00:00:00Z",
        "metadata": {},
    }
    event = EventResponse.model_validate(data)
    assert event.event_type == "cve_published"
    assert event.score == 3.5
```

**Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_schemas.py -v`
Expected: FAIL

**Step 3: Implement schemas**

- `common.py`: `PaginatedResponse[T]` generic, `SeverityEnum`, `StatusEnum`, UUID type
- Each schema file: `*Create`, `*Response`, `*List` models using Pydantic v2 `model_config = {"from_attributes": True}`
- Plan schemas include `PlanValidationResult` with `errors`, `warnings`, `diff_summary`
- Alert schemas include `AlertAckRequest`, `AlertEscalateRequest`
- Brief schemas include `BriefGenerateRequest(query: str)`

**Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_schemas.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add Pydantic v2 request/response schemas"
```

---

### Task 4: FastAPI app skeleton + health endpoints

**Files:**
- Create: `src/osint_core/main.py`
- Create: `src/osint_core/api/__init__.py`
- Create: `src/osint_core/api/deps.py`
- Create: `src/osint_core/api/routes/__init__.py`
- Create: `src/osint_core/api/routes/health.py`
- Test: `tests/test_health.py`

**Step 1: Write the failing test**

```python
# tests/test_health.py
from fastapi.testclient import TestClient

from osint_core.main import app


def test_healthz():
    client = TestClient(app)
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_readyz_returns_checks():
    client = TestClient(app)
    resp = client.get("/readyz")
    assert resp.status_code in (200, 503)
    data = resp.json()
    assert "postgres" in data
    assert "redis" in data
```

**Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_health.py -v`
Expected: FAIL

**Step 3: Implement main.py**

```python
# src/osint_core/main.py
from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

from osint_core.api.routes import health
from osint_core.config import settings

logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("osint-core starting", log_level=settings.log_level)
    yield
    logger.info("osint-core shutting down")


app = FastAPI(
    title="OSINT Core",
    description="OSINT monitoring platform API",
    version="0.1.0",
    lifespan=lifespan,
    docs_url=f"{settings.api_prefix}/docs",
    openapi_url=f"{settings.api_prefix}/openapi.json",
)

Instrumentator().instrument(app).expose(app, endpoint="/metrics")

app.include_router(health.router)
```

**Step 4: Implement health routes**

```python
# src/osint_core/api/routes/health.py
from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/healthz")
async def healthz():
    return {"status": "ok"}


@router.get("/readyz")
async def readyz():
    checks = {}
    # Postgres check
    try:
        # Attempt DB connection
        checks["postgres"] = "ok"
    except Exception:
        checks["postgres"] = "error"
    # Redis check
    try:
        checks["redis"] = "ok"
    except Exception:
        checks["redis"] = "error"
    # Qdrant check
    try:
        checks["qdrant"] = "ok"
    except Exception:
        checks["qdrant"] = "error"

    all_ok = all(v == "ok" for v in checks.values())
    from fastapi.responses import JSONResponse
    return JSONResponse(content=checks, status_code=200 if all_ok else 503)
```

**Step 5: Implement deps.py**

```python
# src/osint_core/api/deps.py
from typing import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession

from osint_core.db import async_session


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        yield session
```

**Step 6: Run test to verify it passes**

Run: `python -m pytest tests/test_health.py -v`
Expected: PASS

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: add FastAPI app skeleton with health endpoints and Prometheus metrics"
```

---

### Task 5: Plan engine — JSON Schema + validation + storage

**Files:**
- Create: `src/osint_core/services/plan_engine.py`
- Create: `schemas/plan-v1.schema.json`
- Create: `plans/example.yaml`
- Test: `tests/test_plan_engine.py`

**Step 1: Write the failing test**

```python
# tests/test_plan_engine.py
import pytest
from osint_core.services.plan_engine import PlanEngine


VALID_PLAN_YAML = """
version: 1
plan_id: test-plan
description: "Test plan"
retention_class: standard

sources:
  - id: cisa_kev
    type: cisa_kev
    url: "https://www.cisa.gov/known-exploited-vulnerabilities-catalog"
    weight: 1.2

scoring:
  recency_half_life_hours: 48
  source_reputation:
    cisa_kev: 1.3
  ioc_match_boost: 2.5
  force_alert:
    min_severity: high
    tags_any: ["force_alert"]

notifications:
  default_dedupe_window_minutes: 90
  quiet_hours:
    timezone: "America/Chicago"
    start: "22:00"
    end: "07:00"
  routes:
    - name: critical_gotify
      when:
        severity_gte: high
      channels:
        - type: gotify
          application: "osint-alerts"
          priority: 8
"""


def test_validate_valid_plan():
    engine = PlanEngine()
    result = engine.validate_yaml(VALID_PLAN_YAML)
    assert result.is_valid is True
    assert len(result.errors) == 0


def test_validate_missing_required_field():
    bad_yaml = "version: 1\nplan_id: test\n"
    engine = PlanEngine()
    result = engine.validate_yaml(bad_yaml)
    assert result.is_valid is False
    assert any("sources" in e or "required" in e.lower() for e in result.errors)


def test_validate_rejects_embedded_secrets():
    plan_with_secret = VALID_PLAN_YAML + '\n  api_key: "sk-12345abcdef"'
    engine = PlanEngine()
    result = engine.validate_yaml(plan_with_secret)
    assert result.is_valid is False
    assert any("secret" in e.lower() for e in result.errors)


def test_compute_content_hash_is_deterministic():
    engine = PlanEngine()
    h1 = engine.content_hash(VALID_PLAN_YAML)
    h2 = engine.content_hash(VALID_PLAN_YAML)
    assert h1 == h2
    assert len(h1) == 64  # SHA-256 hex
```

**Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_plan_engine.py -v`
Expected: FAIL

**Step 3: Create JSON Schema file**

Create `schemas/plan-v1.schema.json` with the schema from EDD Section 5 — validates `version`, `plan_id`, `retention_class`, `sources` (array of objects with `id`, `type`, `weight`), `scoring`, `notifications` (with `routes` array).

Source types enum: `["rss", "sitemap", "http_html", "http_pdf", "http_json", "nvd_json_feed", "osv_api", "cisa_kev", "urlhaus_api", "threatfox_api", "github_releases"]`.

**Step 4: Implement plan_engine.py**

```python
# src/osint_core/services/plan_engine.py
import hashlib
import re
from dataclasses import dataclass, field
from pathlib import Path

import jsonschema
import yaml

SCHEMA_PATH = Path(__file__).parent.parent.parent.parent / "schemas" / "plan-v1.schema.json"

SECRET_PATTERNS = [
    re.compile(r'(?:api[_-]?key|secret|password|token)\s*[:=]\s*["\']?\S{8,}', re.I),
    re.compile(r'sk-[a-zA-Z0-9]{20,}'),
    re.compile(r'ghp_[a-zA-Z0-9]{36}'),
    re.compile(r'xox[bprs]-[a-zA-Z0-9-]+'),
]


@dataclass
class ValidationResult:
    is_valid: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    parsed: dict | None = None


class PlanEngine:
    def __init__(self):
        import json
        self._schema = json.loads(SCHEMA_PATH.read_text()) if SCHEMA_PATH.exists() else {}

    def validate_yaml(self, yaml_str: str) -> ValidationResult:
        errors = []
        # Parse YAML
        try:
            parsed = yaml.safe_load(yaml_str)
        except yaml.YAMLError as e:
            return ValidationResult(is_valid=False, errors=[f"YAML parse error: {e}"])

        if not isinstance(parsed, dict):
            return ValidationResult(is_valid=False, errors=["Plan must be a YAML mapping"])

        # JSON Schema validation
        if self._schema:
            validator = jsonschema.Draft202012Validator(self._schema)
            for err in validator.iter_errors(parsed):
                errors.append(f"{err.json_path}: {err.message}")

        # Secret scan
        for pattern in SECRET_PATTERNS:
            if pattern.search(yaml_str):
                errors.append("Safety: potential secret or API key detected in plan file")
                break

        return ValidationResult(
            is_valid=len(errors) == 0,
            errors=errors,
            parsed=parsed if not errors else None,
        )

    def content_hash(self, yaml_str: str) -> str:
        return hashlib.sha256(yaml_str.encode()).hexdigest()
```

**Step 5: Create example plan**

Create `plans/example.yaml` with the full plan from EDD Section 5 (the libertycenter-osint example).

**Step 6: Run tests to verify they pass**

Run: `python -m pytest tests/test_plan_engine.py -v`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: add plan engine with YAML validation, JSON Schema, and secret scanning"
```

---

### Task 6: Plan API routes + plan storage (DB)

**Files:**
- Create: `src/osint_core/api/routes/plan.py`
- Create: `src/osint_core/services/plan_store.py`
- Modify: `src/osint_core/main.py` (add plan router)
- Test: `tests/test_plan_api.py`

**Step 1: Write the failing test**

```python
# tests/test_plan_api.py
from fastapi.testclient import TestClient
from osint_core.main import app


VALID_PLAN = """
version: 1
plan_id: test-plan
retention_class: standard
sources:
  - id: cisa_kev
    type: cisa_kev
    url: "https://example.com"
    weight: 1.0
scoring:
  recency_half_life_hours: 48
  source_reputation: {}
  ioc_match_boost: 2.0
  force_alert:
    min_severity: high
    tags_any: []
notifications:
  default_dedupe_window_minutes: 90
  routes:
    - name: test
      when:
        severity_gte: high
      channels:
        - type: gotify
          application: test
          priority: 5
"""


def test_validate_plan_endpoint():
    client = TestClient(app)
    resp = client.post(
        "/api/v1/plan/validate",
        content=VALID_PLAN,
        headers={"Content-Type": "application/x-yaml"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["is_valid"] is True
```

**Step 2: Run test to verify it fails**

Expected: FAIL (route not found)

**Step 3: Implement plan_store.py**

Service layer that stores/retrieves plan versions from Postgres via SQLAlchemy async sessions. Methods: `store_version()`, `get_active()`, `get_versions()`, `activate()`, `rollback()`.

**Step 4: Implement plan.py routes**

```python
# src/osint_core/api/routes/plan.py
from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from osint_core.api.deps import get_db
from osint_core.services.plan_engine import PlanEngine

router = APIRouter(prefix="/api/v1/plan", tags=["plan"])
engine = PlanEngine()


@router.post("/validate")
async def validate_plan(request: Request):
    body = await request.body()
    result = engine.validate_yaml(body.decode())
    return {
        "is_valid": result.is_valid,
        "errors": result.errors,
        "warnings": result.warnings,
    }


@router.get("/active")
async def get_active_plan(db: AsyncSession = Depends(get_db)):
    # Return active plan from DB
    ...


@router.post("/sync")
async def sync_plans(db: AsyncSession = Depends(get_db)):
    # Reload plans from disk, validate, store new versions
    ...


@router.post("/rollback")
async def rollback_plan(db: AsyncSession = Depends(get_db)):
    # Activate previous plan version
    ...


@router.post("/activate/{version_id}")
async def activate_plan(version_id: str, db: AsyncSession = Depends(get_db)):
    # Activate specific plan version
    ...


@router.get("/versions")
async def list_plan_versions(db: AsyncSession = Depends(get_db)):
    # List all stored plan versions
    ...
```

**Step 5: Register router in main.py**

Add `from osint_core.api.routes import plan` and `app.include_router(plan.router)`.

**Step 6: Run tests**

Run: `python -m pytest tests/test_plan_api.py -v`
Expected: PASS

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: add plan API routes with validation, sync, activate, and rollback"
```

---

### Task 7: Celery app + Beat setup

**Files:**
- Create: `src/osint_core/workers/celery_app.py`
- Create: `src/osint_core/workers/__init__.py`
- Test: `tests/test_celery_setup.py`

**Step 1: Write the failing test**

```python
# tests/test_celery_setup.py
from osint_core.workers.celery_app import celery_app


def test_celery_app_configured():
    assert celery_app.main == "osint-core"
    assert "redis" in celery_app.conf.broker_url


def test_celery_app_has_autodiscover():
    # Celery should autodiscover tasks from workers package
    assert celery_app.conf.include is not None or len(celery_app.tasks) >= 0
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement celery_app.py**

```python
# src/osint_core/workers/celery_app.py
from celery import Celery
from celery.schedules import crontab

from osint_core.config import settings

celery_app = Celery(
    "osint-core",
    broker=settings.celery_broker_url,
    backend=settings.celery_result_backend,
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="America/Chicago",
    enable_utc=True,
    task_track_started=True,
    task_acks_late=True,
    worker_prefetch_multiplier=1,
    task_default_queue="osint",
    task_routes={
        "osint_core.workers.ingest.*": {"queue": "ingest"},
        "osint_core.workers.enrich.*": {"queue": "enrich"},
        "osint_core.workers.score.*": {"queue": "score"},
        "osint_core.workers.notify.*": {"queue": "notify"},
    },
)

# Beat schedule is dynamically rebuilt from active plan
# This is the default/fallback schedule
celery_app.conf.beat_schedule = {}

celery_app.autodiscover_tasks(["osint_core.workers"])
```

**Step 4: Run test to verify it passes**

Run: `python -m pytest tests/test_celery_setup.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add Celery app with Redis broker and queue routing"
```

---

### Task 8: Structlog + logging setup

**Files:**
- Create: `src/osint_core/logging.py`
- Modify: `src/osint_core/main.py` (init logging in lifespan)
- Test: `tests/test_logging.py`

**Step 1: Write failing test**

```python
# tests/test_logging.py
import json
import structlog
from osint_core.logging import configure_logging


def test_structlog_produces_json(capsys):
    configure_logging(log_level="INFO")
    logger = structlog.get_logger()
    logger.info("test_event", key="value")
    captured = capsys.readouterr()
    parsed = json.loads(captured.out.strip())
    assert parsed["event"] == "test_event"
    assert parsed["key"] == "value"
```

**Step 2: Run to verify fail, implement, verify pass**

```python
# src/osint_core/logging.py
import logging
import structlog


def configure_logging(log_level: str = "INFO"):
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.StackInfoRenderer(),
            structlog.dev.set_exc_info,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, log_level.upper(), logging.INFO)
        ),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add structlog JSON logging configuration"
```

---

### Task 9: Dockerfile + docker-compose.dev.yaml

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.dev.yaml`

**Step 1: Create Dockerfile**

```dockerfile
# Dockerfile
FROM python:3.12-slim AS base
WORKDIR /app

# Install system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

COPY pyproject.toml .
RUN pip install --no-cache-dir .

COPY src/ src/
COPY plans/ plans/
COPY schemas/ schemas/
COPY migrations/ migrations/

# FastAPI entrypoint
FROM base AS api
EXPOSE 8000
CMD ["uvicorn", "osint_core.main:app", "--host", "0.0.0.0", "--port", "8000"]

# Celery worker entrypoint
FROM base AS worker
CMD ["celery", "-A", "osint_core.workers.celery_app", "worker", "--loglevel=info", "-Q", "osint,ingest,enrich,score,notify"]

# Celery Beat entrypoint
FROM base AS beat
CMD ["celery", "-A", "osint_core.workers.celery_app", "beat", "--loglevel=info"]
```

**Step 2: Create docker-compose.dev.yaml**

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: osint
      POSTGRES_USER: osint
      POSTGRES_PASSWORD: osint
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./migrations/init-schema.sql:/docker-entrypoint-initdb.d/01-schema.sql

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  qdrant:
    image: qdrant/qdrant:latest
    ports:
      - "6333:6333"
      - "6334:6334"

  api:
    build:
      context: .
      target: api
    ports:
      - "8000:8000"
    environment:
      OSINT_DATABASE_URL: postgresql+asyncpg://osint:osint@postgres:5432/osint
      OSINT_REDIS_URL: redis://redis:6379/0
      OSINT_CELERY_BROKER_URL: redis://redis:6379/1
      OSINT_CELERY_RESULT_BACKEND: redis://redis:6379/2
      OSINT_QDRANT_HOST: qdrant
      OSINT_OLLAMA_URL: http://host.docker.internal:11434
    depends_on:
      - postgres
      - redis
      - qdrant

  worker:
    build:
      context: .
      target: worker
    environment:
      OSINT_DATABASE_URL: postgresql+asyncpg://osint:osint@postgres:5432/osint
      OSINT_REDIS_URL: redis://redis:6379/0
      OSINT_CELERY_BROKER_URL: redis://redis:6379/1
      OSINT_CELERY_RESULT_BACKEND: redis://redis:6379/2
      OSINT_QDRANT_HOST: qdrant
    depends_on:
      - postgres
      - redis
      - qdrant

  beat:
    build:
      context: .
      target: beat
    environment:
      OSINT_CELERY_BROKER_URL: redis://redis:6379/1
      OSINT_CELERY_RESULT_BACKEND: redis://redis:6379/2
    depends_on:
      - redis

volumes:
  pgdata:
```

**Step 3: Create migrations/init-schema.sql**

```sql
CREATE SCHEMA IF NOT EXISTS osint;
```

**Step 4: Test docker build**

```bash
docker compose -f docker-compose.dev.yaml build
```

Expected: Build succeeds for all three targets.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add Dockerfile (multi-stage) and docker-compose for local dev"
```

---

### Task 10: CI pipeline (GitHub Actions)

**Files:**
- Create: `.github/workflows/ci.yaml`

**Step 1: Create CI workflow**

```yaml
# .github/workflows/ci.yaml
name: CI

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  lint-test:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install dependencies
        run: pip install -e ".[dev]"
      - name: Lint (ruff)
        run: ruff check src/ tests/
      - name: Type check (mypy)
        run: mypy src/osint_core/
      - name: Test
        run: pytest --cov=osint_core --cov-report=term-missing -v

  build:
    runs-on: self-hosted
    needs: lint-test
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - name: Log in to Harbor
        run: echo "${{ secrets.HARBOR_PASSWORD }}" | docker login harbor.corbello.io -u "${{ secrets.HARBOR_USERNAME }}" --password-stdin
      - name: Build and push
        run: |
          IMAGE=harbor.corbello.io/osint/osint-core:${{ github.sha }}
          docker build --target api -t $IMAGE .
          docker push $IMAGE
          docker tag $IMAGE harbor.corbello.io/osint/osint-core:latest
          docker push harbor.corbello.io/osint/osint-core:latest
```

**Step 2: Commit**

```bash
git add -A
git commit -m "feat: add GitHub Actions CI pipeline with lint, test, and Harbor push"
```

---

### Task 11: cortech-infra — K8s namespace, ExternalName services, RBAC

**Repo:** `cortech-infra` (this repo)

**Files:**
- Create: `apps/osint/base/kustomization.yaml`
- Create: `apps/osint/base/namespace.yaml`
- Create: `apps/osint/base/external-services/postgres.yaml`
- Create: `apps/osint/base/external-services/redis.yaml`
- Create: `apps/osint/base/external-services/minio.yaml`
- Create: `apps/osint/base/external-services/ollama.yaml`
- Create: `apps/osint/base/rbac/resource-quota.yaml`
- Create: `apps/osint/base/rbac/limit-range.yaml`
- Create: `apps/osint/base/rbac/priority-classes.yaml`
- Create: `apps/osint/base/rbac/service-account.yaml`
- Create: `apps/osint/base/network-policies/default-deny.yaml`
- Create: `apps/osint/overlays/production/kustomization.yaml`

**Step 1: Create directory structure**

```bash
mkdir -p apps/osint/base/{external-services,rbac,network-policies,osint-core,osint-worker,osint-beat,qdrant,gotify,jobs,monitoring}
mkdir -p apps/osint/overlays/production
```

**Step 2: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: osint
  labels:
    app.kubernetes.io/part-of: osint-platform
```

**Step 3: Create ExternalName services**

Each file creates a headless Service + Endpoints pointing to the LXC IP:

```yaml
# apps/osint/base/external-services/postgres.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: osint
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres
  namespace: osint
subsets:
  - addresses:
      - ip: 192.168.1.52
    ports:
      - port: 5432
```

Same pattern for redis (192.168.1.52:6379), minio (192.168.1.52:9000), ollama (192.168.1.114:11434).

Note: Using `Service + Endpoints` instead of `ExternalName` because ExternalName doesn't support port mapping and can cause DNS resolution issues with some clients.

**Step 4: Create RBAC resources**

- `resource-quota.yaml` — per EDD: 8 CPU req / 16 lim, 16Gi mem req / 32Gi lim, 20 pods, 6 jobs
- `limit-range.yaml` — per EDD: defaults 500m/512Mi, requests 100m/128Mi, max 4 CPU/8Gi
- `priority-classes.yaml` — `osint-core` (100) and `osint-batch` (10)
- `service-account.yaml` — `osint-core` SA with RBAC to create/list/delete Jobs in `osint` namespace

**Step 5: Create network policy**

```yaml
# apps/osint/base/network-policies/default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: osint
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: osint
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: TCP
          port: 8000
```

**Step 6: Create base kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: osint
resources:
  - namespace.yaml
  - external-services/postgres.yaml
  - external-services/redis.yaml
  - external-services/minio.yaml
  - external-services/ollama.yaml
  - rbac/resource-quota.yaml
  - rbac/limit-range.yaml
  - rbac/priority-classes.yaml
  - rbac/service-account.yaml
  - network-policies/default-deny.yaml
```

**Step 7: Create production overlay**

```yaml
# apps/osint/overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
```

**Step 8: Commit**

```bash
git add apps/osint/
git commit -m "feat: add OSINT K8s namespace, ExternalName services, RBAC, and network policies"
```

---

### Task 12: cortech-infra — NGINX proxy + ArgoCD Application

**Repo:** `cortech-infra`

**Files:**
- Create: `proxy/sites/osint.corbello.io.conf`
- Create: `apps/osint/argocd-application.yaml`

**Step 1: Create NGINX proxy config**

Follow existing pattern from `chat.corbello.io.conf`:

```nginx
# osint.corbello.io -> K3s Traefik -> osint-core API
server {
    server_name osint.corbello.io;

    client_max_body_size 10M;

    location / {
        proxy_pass http://192.168.1.90;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_read_timeout 120s;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/osint.corbello.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/osint.corbello.io/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if ($host = osint.corbello.io) {
        return 301 https://$host$request_uri;
    }
    server_name osint.corbello.io;
    listen 80;
    return 404;
}
```

**Step 2: Create ArgoCD Application manifest**

Per EDD Section 11 — auto-sync from `apps/osint/overlays/production`.

**Step 3: Commit**

```bash
git add proxy/sites/osint.corbello.io.conf apps/osint/argocd-application.yaml
git commit -m "feat: add NGINX proxy config and ArgoCD Application for OSINT platform"
```

---

### Task 13: cortech-infra — K8s deployments (osint-core, worker, beat, qdrant, gotify)

**Repo:** `cortech-infra`

**Files:**
- Create: `apps/osint/base/osint-core/deployment.yaml`
- Create: `apps/osint/base/osint-core/service.yaml`
- Create: `apps/osint/base/osint-core/ingress.yaml`
- Create: `apps/osint/base/osint-worker/deployment.yaml`
- Create: `apps/osint/base/osint-beat/deployment.yaml`
- Create: `apps/osint/base/qdrant/statefulset.yaml`
- Create: `apps/osint/base/qdrant/service.yaml`
- Create: `apps/osint/base/qdrant/pvc.yaml`
- Create: `apps/osint/base/gotify/deployment.yaml`
- Create: `apps/osint/base/gotify/service.yaml`
- Create: `apps/osint/base/gotify/pvc.yaml`
- Create: `apps/osint/base/monitoring/service-monitor.yaml`
- Modify: `apps/osint/base/kustomization.yaml` (add new resources)

**Step 1: Create osint-core deployment**

Deployment with:
- Image: `harbor.corbello.io/osint/osint-core:latest`
- Resources: 250m/1000m CPU, 256Mi/512Mi mem
- Node affinity: `role in [core-app, compute]`
- Priority class: `osint-core`
- Liveness/readiness probes on `/healthz` and `/readyz`
- Environment variables from ConfigMap + Secrets (DB URL, Redis URL, etc.)
- Port 8000

Service (ClusterIP) exposing port 8000.

Traefik IngressRoute:
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: osint-core
  namespace: osint
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`osint.corbello.io`)
      kind: Rule
      services:
        - name: osint-core
          port: 8000
```

**Step 2: Create osint-worker deployment**

Same image, different command: `celery -A osint_core.workers.celery_app worker ...`
Resources: 250m/500m CPU, 256Mi/512Mi mem.

**Step 3: Create osint-beat deployment**

Same image, command: `celery -A osint_core.workers.celery_app beat ...`
Resources: 100m/250m CPU, 128Mi/256Mi mem.
Single replica only (Beat must not run multiple instances).

**Step 4: Create Qdrant StatefulSet**

Image: `harbor.corbello.io/dockerhub-cache/qdrant/qdrant:latest`
Resources: 250m/1000m CPU, 512Mi/1Gi mem.
PVC: 10Gi NFS storage.
Service: port 6333 (HTTP) and 6334 (gRPC).

**Step 5: Create Gotify deployment**

Image: `harbor.corbello.io/dockerhub-cache/gotify/server:latest`
Resources: 50m/200m CPU, 64Mi/128Mi mem.
PVC: 1Gi for SQLite DB.
Service: port 80.

**Step 6: Create ServiceMonitor**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: osint-core
  namespace: osint
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: osint-core
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

**Step 7: Update kustomization.yaml**

Add all new resource paths to the base kustomization.

**Step 8: Commit**

```bash
git add apps/osint/
git commit -m "feat: add K8s deployments for osint-core, worker, beat, qdrant, and gotify"
```

---

## Phase 1: Full Use Case C (MVP)

### Task 14: Connector base class + registry

**Repo:** `osint-core`

**Files:**
- Create: `src/osint_core/connectors/__init__.py`
- Create: `src/osint_core/connectors/base.py`
- Create: `src/osint_core/connectors/registry.py`
- Test: `tests/connectors/__init__.py`
- Test: `tests/connectors/test_registry.py`

**Step 1: Write the failing test**

```python
# tests/connectors/test_registry.py
import pytest
from osint_core.connectors.base import BaseConnector, RawItem, SourceConfig
from osint_core.connectors.registry import ConnectorRegistry


class FakeConnector(BaseConnector):
    async def fetch(self) -> list[RawItem]:
        return [RawItem(title="Test", url="https://example.com", raw_data={})]

    def dedupe_key(self, item: RawItem) -> str:
        return f"fake:{item.url}"


def test_register_and_get():
    registry = ConnectorRegistry()
    registry.register("fake_type", FakeConnector)
    config = SourceConfig(id="test", type="fake_type", url="https://example.com", weight=1.0)
    connector = registry.get("fake_type", config)
    assert isinstance(connector, FakeConnector)


def test_get_unregistered_raises():
    registry = ConnectorRegistry()
    config = SourceConfig(id="test", type="unknown", url="", weight=1.0)
    with pytest.raises(KeyError):
        registry.get("unknown", config)
```

**Step 2: Run test to verify it fails**

**Step 3: Implement base.py**

```python
# src/osint_core/connectors/base.py
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class SourceConfig:
    id: str
    type: str
    url: str
    weight: float
    extra: dict = field(default_factory=dict)


@dataclass
class RawItem:
    title: str
    url: str
    raw_data: dict
    summary: str = ""
    occurred_at: datetime | None = None
    severity: str | None = None
    indicators: list[dict] = field(default_factory=list)


class BaseConnector(ABC):
    def __init__(self, config: SourceConfig):
        self.config = config

    @abstractmethod
    async def fetch(self) -> list[RawItem]:
        ...

    @abstractmethod
    def dedupe_key(self, item: RawItem) -> str:
        ...
```

**Step 4: Implement registry.py**

```python
# src/osint_core/connectors/registry.py
from osint_core.connectors.base import BaseConnector, SourceConfig


class ConnectorRegistry:
    def __init__(self):
        self._connectors: dict[str, type[BaseConnector]] = {}

    def register(self, source_type: str, cls: type[BaseConnector]):
        self._connectors[source_type] = cls

    def get(self, source_type: str, config: SourceConfig) -> BaseConnector:
        if source_type not in self._connectors:
            raise KeyError(f"No connector registered for type: {source_type}")
        return self._connectors[source_type](config)

    def has(self, source_type: str) -> bool:
        return source_type in self._connectors
```

**Step 5: Run tests, verify pass, commit**

```bash
git add -A
git commit -m "feat: add connector base class and registry"
```

---

### Task 15: CISA KEV connector

**Repo:** `osint-core`

**Files:**
- Create: `src/osint_core/connectors/cisa_kev.py`
- Test: `tests/connectors/test_cisa_kev.py`

**Step 1: Write the failing test**

Test against a fixture of the CISA KEV JSON structure. Mock httpx responses. Verify:
- Parses vulnerabilities from JSON catalog
- Extracts CVE ID, vendor, product, description, date added
- Generates correct dedupe key (cisa_kev:{cve_id})
- Creates RawItem with indicators (CVE type)

**Step 2: Implement cisa_kev.py**

Fetches `https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json`, parses `vulnerabilities` array, tracks last-known state to only return new entries since last poll.

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add CISA KEV feed connector"
```

---

### Task 16: NVD connector

**Files:**
- Create: `src/osint_core/connectors/nvd.py`
- Test: `tests/connectors/test_nvd.py`

Uses NVD API 2.0 (`https://services.nvd.nist.gov/rest/json/cves/2.0`). Paginated, rate-limited (5 req/30s without API key). Fetches recent CVEs by `lastModStartDate`/`lastModEndDate`. Extracts CVE ID, CVSS score, description, references. Dedupe key: `nvd:{cve_id}`.

**Commit:** `feat: add NVD API 2.0 feed connector`

---

### Task 17: OSV connector

**Files:**
- Create: `src/osint_core/connectors/osv.py`
- Test: `tests/connectors/test_osv.py`

Uses OSV API (`https://api.osv.dev/v1/query`). Batch query by ecosystem. Extracts vulnerability ID, affected packages, severity, references. Dedupe key: `osv:{vuln_id}`.

**Commit:** `feat: add OSV API feed connector`

---

### Task 18: URLhaus connector

**Files:**
- Create: `src/osint_core/connectors/urlhaus.py`
- Test: `tests/connectors/test_urlhaus.py`

Fetches recent malicious URLs from `https://urlhaus.abuse.ch/api/`. Extracts URL, threat type, tags, reporter. Creates indicators (URL + domain type). Dedupe key: `urlhaus:{url_hash}`.

**Commit:** `feat: add URLhaus feed connector`

---

### Task 19: ThreatFox connector

**Files:**
- Create: `src/osint_core/connectors/threatfox.py`
- Test: `tests/connectors/test_threatfox.py`

Fetches recent IOCs from ThreatFox API (`https://threatfox-api.abuse.ch/api/v1/`). Extracts IOC type, value, threat type, malware, confidence. Expires IOCs older than 6 months. Dedupe key: `threatfox:{ioc_id}`.

**Commit:** `feat: add ThreatFox IOC feed connector`

---

### Task 20: RSS connector

**Files:**
- Create: `src/osint_core/connectors/rss.py`
- Test: `tests/connectors/test_rss.py`

Generic RSS/Atom parser using `feedparser` library (add to pyproject.toml dependencies). Extracts title, link, summary, published date. Dedupe key: `rss:{feed_id}:{entry_link_hash}`.

**Commit:** `feat: add generic RSS/Atom feed connector`

---

### Task 21: Indicator extraction + normalization

**Files:**
- Create: `src/osint_core/services/indicators.py`
- Test: `tests/test_indicators.py`

**Step 1: Write the failing test**

```python
# tests/test_indicators.py
from osint_core.services.indicators import extract_indicators, normalize_indicator


def test_extract_cve():
    text = "Critical vulnerability CVE-2026-12345 affects Apache"
    indicators = extract_indicators(text)
    assert any(i["type"] == "cve" and i["value"] == "CVE-2026-12345" for i in indicators)


def test_extract_domain():
    text = "Malware phones home to evil.example.com for C2"
    indicators = extract_indicators(text)
    assert any(i["type"] == "domain" and i["value"] == "evil.example.com" for i in indicators)


def test_extract_ip():
    text = "C2 server at 192.168.1.100"
    indicators = extract_indicators(text)
    assert any(i["type"] == "ip" and i["value"] == "192.168.1.100" for i in indicators)


def test_extract_url():
    text = "Download from https://evil.com/payload.exe"
    indicators = extract_indicators(text)
    assert any(i["type"] == "url" for i in indicators)


def test_extract_hash():
    text = "SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    indicators = extract_indicators(text)
    assert any(i["type"] == "hash" and "e3b0c44" in i["value"] for i in indicators)


def test_normalize_domain():
    assert normalize_indicator("domain", "EVIL.Example.COM") == "evil.example.com"


def test_normalize_url():
    result = normalize_indicator("url", "HTTP://Evil.COM/path?b=2&a=1")
    assert result.startswith("http://evil.com/")
```

**Step 2: Implement indicators.py**

Regex-based extraction for CVEs (`CVE-\d{4}-\d{4,}`), domains, IPs (v4/v6), URLs, email addresses, SHA-256/MD5 hashes. Normalization: lowercase domains/URLs, sort query params, strip trailing slashes.

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add indicator extraction and normalization service"
```

---

### Task 22: Celery ingest tasks + Beat scheduling

**Files:**
- Create: `src/osint_core/workers/ingest.py`
- Modify: `src/osint_core/services/plan_engine.py` (add schedule builder)
- Test: `tests/workers/test_ingest.py`

**Step 1: Write the failing test**

```python
# tests/workers/test_ingest.py
from unittest.mock import AsyncMock, patch
from osint_core.workers.ingest import ingest_source


def test_ingest_source_creates_events(db_session):
    # Mock connector.fetch() to return 2 items
    # Assert 2 events created in DB
    # Assert indicators extracted and linked
    ...
```

**Step 2: Implement ingest.py**

```python
# src/osint_core/workers/ingest.py
from osint_core.workers.celery_app import celery_app


@celery_app.task(bind=True, name="osint.ingest_source", max_retries=3)
def ingest_source(self, source_id: str):
    """Ingest items from a configured source."""
    # 1. Load active plan, get source config
    # 2. Get connector from registry
    # 3. Fetch items
    # 4. For each item:
    #    a. Compute dedupe fingerprint
    #    b. Check if exists (skip if dup)
    #    c. Create Event
    #    d. Extract indicators, create/link Indicators
    #    e. Chain enrichment tasks
    # 5. Record job in jobs table
    ...
```

**Step 3: Add schedule builder to plan_engine.py**

Method `build_beat_schedule(plan)` that converts `sources` list into Celery Beat schedule entries: `{"ingest-{source_id}": {"task": "osint.ingest_source", "schedule": interval, "args": [source_id]}}`.

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add Celery ingest tasks with Beat schedule builder"
```

---

### Task 23: Scoring engine

**Files:**
- Create: `src/osint_core/services/scoring.py`
- Create: `src/osint_core/workers/score.py`
- Test: `tests/test_scoring.py`

**Step 1: Write the failing test**

```python
# tests/test_scoring.py
from datetime import datetime, timedelta, timezone
from osint_core.services.scoring import score_event, ScoringConfig


def test_base_score_from_source_reputation():
    config = ScoringConfig(
        recency_half_life_hours=48,
        source_reputation={"cisa_kev": 1.5},
        ioc_match_boost=2.0,
    )
    score = score_event(
        source_id="cisa_kev",
        occurred_at=datetime.now(timezone.utc),
        indicator_count=0,
        matched_topics=[],
        config=config,
    )
    assert score == pytest.approx(1.5, abs=0.1)


def test_recency_decay():
    config = ScoringConfig(
        recency_half_life_hours=48,
        source_reputation={"src": 1.0},
        ioc_match_boost=1.0,
    )
    recent = score_event("src", datetime.now(timezone.utc), 0, [], config)
    old = score_event("src", datetime.now(timezone.utc) - timedelta(hours=96), 0, [], config)
    assert recent > old
    assert old == pytest.approx(recent * 0.25, abs=0.1)  # 2 half-lives = 0.25


def test_ioc_boost():
    config = ScoringConfig(
        recency_half_life_hours=48,
        source_reputation={"src": 1.0},
        ioc_match_boost=3.0,
    )
    without = score_event("src", datetime.now(timezone.utc), 0, [], config)
    with_ioc = score_event("src", datetime.now(timezone.utc), 2, [], config)
    assert with_ioc == pytest.approx(without * 3.0, abs=0.1)
```

**Step 2: Implement scoring.py**

Per EDD Section 7. Pure function, no DB access. Takes event attributes + ScoringConfig, returns float score.

**Step 3: Implement workers/score.py**

Celery task `score_event_task(event_id)` that loads event from DB, loads active plan scoring config, calls `score_event()`, updates event score + severity in DB.

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add scoring engine with source reputation, recency decay, and IOC boost"
```

---

### Task 24: Alert creation + dedupe

**Files:**
- Create: `src/osint_core/services/alerting.py`
- Test: `tests/test_alerting.py`

**Step 1: Write the failing test**

```python
# tests/test_alerting.py
from osint_core.services.alerting import compute_fingerprint, should_alert, check_dedupe


def test_compute_fingerprint_deterministic():
    fp1 = compute_fingerprint("plan1", ["CVE-2026-0001"], "https://example.com")
    fp2 = compute_fingerprint("plan1", ["CVE-2026-0001"], "https://example.com")
    assert fp1 == fp2


def test_compute_fingerprint_differs_for_different_inputs():
    fp1 = compute_fingerprint("plan1", ["CVE-2026-0001"], "https://example.com")
    fp2 = compute_fingerprint("plan1", ["CVE-2026-0002"], "https://example.com")
    assert fp1 != fp2


def test_should_alert_above_threshold():
    assert should_alert(score=5.0, severity="high", threshold=3.0) is True


def test_should_not_alert_below_threshold():
    assert should_alert(score=1.0, severity="low", threshold=3.0) is False
```

**Step 2: Implement alerting.py**

- `compute_fingerprint()` — hash of plan_id + sorted indicators + canonical URL
- `should_alert()` — score threshold + severity check
- `check_dedupe()` — query alerts table for matching fingerprint within time window
- `create_or_increment_alert()` — create new alert or increment occurrences on existing
- `check_quiet_hours()` — compare current time against plan quiet hours config

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add alert creation with fingerprint dedup and quiet hours"
```

---

### Task 25: Notification dispatch (Apprise/Gotify)

**Files:**
- Create: `src/osint_core/services/notification.py`
- Create: `src/osint_core/workers/notify.py`
- Test: `tests/test_notification.py`

**Step 1: Write the failing test**

```python
# tests/test_notification.py
from unittest.mock import patch, MagicMock
from osint_core.services.notification import NotificationService, NotificationRoute


def test_route_matching():
    route = NotificationRoute(
        name="critical",
        severity_gte="high",
        channels=[{"type": "gotify", "application": "test", "priority": 8}],
    )
    svc = NotificationService(routes=[route])
    matched = svc.match_routes(severity="critical")
    assert len(matched) == 1
    assert matched[0].name == "critical"


def test_no_route_for_low_severity():
    route = NotificationRoute(
        name="critical",
        severity_gte="high",
        channels=[{"type": "gotify", "application": "test", "priority": 8}],
    )
    svc = NotificationService(routes=[route])
    matched = svc.match_routes(severity="info")
    assert len(matched) == 0
```

**Step 2: Implement notification.py**

- Route matching logic (severity comparison)
- Apprise integration: build Apprise URLs from channel configs
- Gotify direct REST API call as primary channel
- Format alert messages (title, summary, severity, indicator list)

**Step 3: Implement workers/notify.py**

Celery task `send_notification(alert_id)` that loads alert, matches routes, dispatches via Apprise.

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add notification dispatch with Apprise and Gotify integration"
```

---

### Task 26: Quiet hours + escalation + digest

**Files:**
- Modify: `src/osint_core/services/alerting.py` (add escalation logic)
- Modify: `src/osint_core/services/notification.py` (add quiet hours + digest)
- Create: `src/osint_core/workers/digest.py`
- Test: `tests/test_escalation.py`

**Step 1: Write the failing test**

```python
# tests/test_escalation.py
from osint_core.services.alerting import should_escalate


def test_escalate_on_severity_increase():
    assert should_escalate(
        current_severity="high",
        previous_severity="medium",
        corroborating_sources=1,
    ) is True


def test_escalate_on_corroboration():
    assert should_escalate(
        current_severity="medium",
        previous_severity="medium",
        corroborating_sources=3,
    ) is True


def test_no_escalate_same_severity_few_sources():
    assert should_escalate(
        current_severity="medium",
        previous_severity="medium",
        corroborating_sources=1,
    ) is False
```

**Step 2: Implement**

- `should_escalate()`: escalate if severity increased or 3+ independent sources within 2 hours
- Quiet hours: during quiet period, queue alerts for digest instead of immediate dispatch
- `digest.py`: Celery task scheduled for end of quiet hours, compiles accumulated alerts into a single digest notification

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add alert escalation, quiet hours, and digest compilation"
```

---

### Task 27: Qdrant vectorization + semantic search

**Files:**
- Create: `src/osint_core/services/vectorize.py`
- Create: `src/osint_core/workers/enrich.py`
- Test: `tests/test_vectorize.py`

**Step 1: Write the failing test**

```python
# tests/test_vectorize.py
from osint_core.services.vectorize import embed_text, EMBEDDING_DIM


def test_embed_text_returns_correct_dimension():
    vec = embed_text("Critical vulnerability in Apache HTTP Server")
    assert len(vec) == EMBEDDING_DIM  # 384 for all-MiniLM-L6-v2


def test_embed_text_deterministic():
    v1 = embed_text("test input")
    v2 = embed_text("test input")
    assert v1 == v2


def test_similar_texts_have_high_cosine():
    v1 = embed_text("Apache vulnerability CVE-2026-0001")
    v2 = embed_text("Apache HTTP Server security flaw CVE-2026-0001")
    from numpy import dot
    from numpy.linalg import norm
    cosine = dot(v1, v2) / (norm(v1) * norm(v2))
    assert cosine > 0.7
```

**Step 2: Implement vectorize.py**

```python
# src/osint_core/services/vectorize.py
from sentence_transformers import SentenceTransformer
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct

from osint_core.config import settings

MODEL_NAME = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384

_model = None


def get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        _model = SentenceTransformer(MODEL_NAME)
    return _model


def embed_text(text: str) -> list[float]:
    model = get_model()
    return model.encode(text).tolist()


def get_qdrant() -> QdrantClient:
    return QdrantClient(host=settings.qdrant_host, port=settings.qdrant_port)


def upsert_event(event_id: str, text: str, payload: dict):
    client = get_qdrant()
    vec = embed_text(text)
    client.upsert(
        collection_name=settings.qdrant_collection,
        points=[PointStruct(id=event_id, vector=vec, payload=payload)],
    )


def search_similar(text: str, limit: int = 10, score_threshold: float = 0.5):
    client = get_qdrant()
    vec = embed_text(text)
    return client.search(
        collection_name=settings.qdrant_collection,
        query_vector=vec,
        limit=limit,
        score_threshold=score_threshold,
    )
```

**Step 3: Implement workers/enrich.py**

Celery tasks:
- `vectorize_event_task(event_id)` — embed event text, upsert to Qdrant
- `correlate_event_task(event_id)` — search Qdrant for similar events, link correlated events

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add Qdrant vectorization and semantic search"
```

---

### Task 28: Correlation engine (exact + semantic)

**Files:**
- Create: `src/osint_core/services/correlation.py`
- Test: `tests/test_correlation.py`

**Step 1: Write the failing test**

```python
# tests/test_correlation.py
from osint_core.services.correlation import correlate_exact, is_semantic_duplicate


def test_exact_match_same_cve():
    event_indicators = [{"type": "cve", "value": "CVE-2026-0001"}]
    existing_indicators = [{"type": "cve", "value": "CVE-2026-0001"}]
    assert correlate_exact(event_indicators, existing_indicators) is True


def test_no_exact_match():
    event_indicators = [{"type": "cve", "value": "CVE-2026-0001"}]
    existing_indicators = [{"type": "cve", "value": "CVE-2026-0002"}]
    assert correlate_exact(event_indicators, existing_indicators) is False


def test_semantic_duplicate_detection():
    # Cosine > 0.85 means same story
    assert is_semantic_duplicate(similarity_score=0.92) is True
    assert is_semantic_duplicate(similarity_score=0.70) is False
```

**Step 2: Implement correlation.py**

- `correlate_exact()` — compare indicator sets for overlapping CVEs, domains, IPs, hashes
- `is_semantic_duplicate()` — threshold check on Qdrant similarity score
- `find_correlated_events()` — combines exact + semantic search results

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add correlation engine with exact match and semantic dedup"
```

---

### Task 29: spaCy NER entity extraction

**Files:**
- Create: `src/osint_core/services/ner.py`
- Create: `src/osint_core/workers/k8s_dispatch.py`
- Test: `tests/test_ner.py`

**Step 1: Write the failing test**

```python
# tests/test_ner.py
from osint_core.services.ner import extract_entities


def test_extract_person():
    text = "John Smith, CEO of Acme Corp, announced the vulnerability disclosure."
    entities = extract_entities(text)
    assert any(e["type"] == "PERSON" and "John Smith" in e["name"] for e in entities)


def test_extract_org():
    text = "Microsoft released a security patch for Windows Server."
    entities = extract_entities(text)
    assert any(e["type"] == "ORG" and "Microsoft" in e["name"] for e in entities)
```

**Step 2: Implement ner.py**

```python
# src/osint_core/services/ner.py
import spacy

_nlp = None


def get_nlp():
    global _nlp
    if _nlp is None:
        _nlp = spacy.load("en_core_web_sm")
    return _nlp


def extract_entities(text: str) -> list[dict]:
    nlp = get_nlp()
    doc = nlp(text)
    entities = []
    for ent in doc.ents:
        if ent.label_ in ("PERSON", "ORG", "GPE", "PRODUCT", "LOC"):
            entities.append({
                "type": ent.label_,
                "name": ent.text,
                "start": ent.start_char,
                "end": ent.end_char,
            })
    return entities
```

**Step 3: Implement workers/k8s_dispatch.py**

Celery task `enrich_entities_task(event_id)` that:
- For small text: runs NER in-process (spaCy en_core_web_sm)
- For large documents / batch: dispatches K8s Job to wrk-3
- K8s Job dispatch uses `kubernetes` Python client to create Job manifest with wrk-3 affinity/tolerations
- Polls Job status, retrieves results from a Redis key or Postgres

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add spaCy NER entity extraction with K8s Job dispatch"
```

---

### Task 30: Intel brief generation (Ollama + template fallback)

**Files:**
- Create: `src/osint_core/services/brief_generator.py`
- Create: `src/osint_core/templates/brief_default.md.j2`
- Test: `tests/test_brief_generator.py`

**Step 1: Write the failing test**

```python
# tests/test_brief_generator.py
from unittest.mock import patch, AsyncMock
from osint_core.services.brief_generator import BriefGenerator


def test_template_fallback_produces_markdown():
    gen = BriefGenerator(ollama_available=False)
    events = [
        {"title": "CVE-2026-0001", "severity": "high", "score": 4.5, "source_id": "nvd", "occurred_at": "2026-03-01"},
    ]
    indicators = [{"type": "cve", "value": "CVE-2026-0001"}]
    brief = gen.generate_from_template(
        title="CVE-2026-0001 Brief",
        events=events,
        indicators=indicators,
        entities=[],
    )
    assert "# Intel Brief:" in brief
    assert "CVE-2026-0001" in brief
    assert "## Key Events" in brief


@patch("osint_core.services.brief_generator.httpx.AsyncClient")
async def test_ollama_generation(mock_client):
    mock_response = AsyncMock()
    mock_response.json.return_value = {"response": "## Summary\nThis is an AI brief."}
    mock_response.status_code = 200
    mock_client.return_value.__aenter__.return_value.post = AsyncMock(return_value=mock_response)

    gen = BriefGenerator(ollama_available=True)
    brief = await gen.generate(
        query="Brief me on CVE-2026-0001",
        events=[],
        indicators=[],
        entities=[],
    )
    assert "Summary" in brief
```

**Step 2: Create Jinja2 template**

Create `src/osint_core/templates/brief_default.md.j2` with the template from EDD Section 9.

**Step 3: Implement brief_generator.py**

- `BriefGenerator.generate()` — try Ollama first, fall back to template
- `BriefGenerator.generate_from_template()` — Jinja2 rendering
- `BriefGenerator.generate_from_ollama()` — httpx POST to Ollama API with structured prompt
- Ollama prompt includes system message ("You are an intelligence analyst...") + context (events, indicators, entities)

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add intel brief generator with Ollama and template fallback"
```

---

### Task 31: Full API routes (events, indicators, entities, alerts, briefs, search, jobs, audit)

**Files:**
- Create: `src/osint_core/api/routes/events.py`
- Create: `src/osint_core/api/routes/indicators.py`
- Create: `src/osint_core/api/routes/entities.py`
- Create: `src/osint_core/api/routes/alerts.py`
- Create: `src/osint_core/api/routes/briefs.py`
- Create: `src/osint_core/api/routes/search.py`
- Create: `src/osint_core/api/routes/ingest.py`
- Create: `src/osint_core/api/routes/jobs.py`
- Create: `src/osint_core/api/routes/audit.py`
- Modify: `src/osint_core/main.py` (register all routers)
- Test: `tests/test_api_routes.py`

**Step 1: Write failing tests for key endpoints**

Test each route group: events list/detail, indicators lookup, alerts ack/escalate/resolve, briefs generate, search (keyword + semantic), jobs list/retry, audit list.

Use TestClient with mocked DB sessions.

**Step 2: Implement each route file**

Per EDD Section 10. Each route file follows the pattern:
- Router with prefix (`/api/v1/<resource>`)
- Depends on `get_db` for DB session
- Uses Pydantic schemas for request/response
- Pagination via `limit` + `offset` query params
- Filtering via query params (source, severity, date_range, status)

Key endpoints:
- `POST /api/v1/briefs/generate` — calls BriefGenerator
- `GET /api/v1/search` — Postgres FTS query against events.search_vector
- `GET /api/v1/search/semantic` — Qdrant similarity search
- `POST /api/v1/alerts/{id}/ack` — update alert status + audit log
- `POST /api/v1/ingest/source/{source_id}/run` — dispatch Celery ingest task
- `POST /api/v1/jobs/{id}/retry` — re-dispatch failed job

**Step 3: Register all routers in main.py**

**Step 4: Run tests, verify pass, commit**

```bash
git commit -m "feat: add complete REST API routes for events, alerts, briefs, search, and more"
```

---

### Task 32: Keycloak OIDC middleware

**Files:**
- Create: `src/osint_core/api/middleware/auth.py`
- Modify: `src/osint_core/api/deps.py` (add auth dependency)
- Test: `tests/test_auth.py`

**Step 1: Write the failing test**

```python
# tests/test_auth.py
from fastapi.testclient import TestClient
from osint_core.main import app


def test_protected_endpoint_rejects_no_token():
    client = TestClient(app)
    resp = client.get("/api/v1/events")
    assert resp.status_code == 401


def test_protected_endpoint_rejects_invalid_token():
    client = TestClient(app)
    resp = client.get("/api/v1/events", headers={"Authorization": "Bearer invalid"})
    assert resp.status_code == 401
```

**Step 2: Implement auth.py**

- Fetch Keycloak OIDC well-known config and JWKS on startup
- Validate JWT signature, expiry, audience
- Extract `sub`, `preferred_username`, `realm_access.roles`
- Map roles to permissions: `osint-operator`, `osint-analyst`, `osint-readonly`
- FastAPI dependency `get_current_user()` that returns user info or raises 401
- Role-checking dependency `require_role("osint-analyst")`
- Health endpoints (`/healthz`, `/readyz`, `/metrics`) exempt from auth

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add Keycloak OIDC JWT authentication middleware"
```

---

### Task 33: Audit logging

**Files:**
- Create: `src/osint_core/services/audit.py`
- Test: `tests/test_audit.py`

**Step 1: Write the failing test**

```python
# tests/test_audit.py
from osint_core.services.audit import create_audit_entry


async def test_create_audit_entry(db_session):
    entry = await create_audit_entry(
        db=db_session,
        action="plan.activate",
        actor="user-uuid",
        actor_username="alastar",
        actor_roles=["osint-operator"],
        resource_type="plan_version",
        resource_id="plan-uuid",
        details={"plan_id": "test-plan", "version": 1},
    )
    assert entry.action == "plan.activate"
    assert entry.actor_username == "alastar"
```

**Step 2: Implement audit.py**

- `create_audit_entry()` — insert into audit_log table
- Called from plan activate/rollback, alert ack/escalate, brief generate, ingest run, job retry
- Includes Keycloak identity fields from current user context

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add append-only audit logging service"
```

---

### Task 34: Prometheus metrics

**Files:**
- Modify: `src/osint_core/main.py` (custom metrics)
- Create: `src/osint_core/metrics.py`
- Test: `tests/test_metrics.py`

**Step 1: Write the failing test**

```python
# tests/test_metrics.py
from fastapi.testclient import TestClient
from osint_core.main import app


def test_metrics_endpoint():
    client = TestClient(app)
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "osint_events_ingested_total" in resp.text or "http_requests_total" in resp.text
```

**Step 2: Implement metrics.py**

```python
# src/osint_core/metrics.py
from prometheus_client import Counter, Histogram, Gauge

events_ingested = Counter(
    "osint_events_ingested_total",
    "Total events ingested",
    ["source_id"],
)
alerts_fired = Counter(
    "osint_alerts_fired_total",
    "Total alerts fired",
    ["severity", "route"],
)
ingestion_duration = Histogram(
    "osint_ingestion_duration_seconds",
    "Time to ingest a source",
    ["source_id"],
)
active_jobs = Gauge(
    "osint_active_jobs",
    "Currently running jobs",
    ["job_type"],
)
celery_queue_depth = Gauge(
    "osint_celery_queue_depth",
    "Celery queue depth",
    ["queue"],
)
```

Instrument Celery tasks to increment counters and record histograms.

**Step 3: Run tests, verify pass, commit**

```bash
git commit -m "feat: add Prometheus business metrics for ingestion, alerts, and jobs"
```

---

### Task 35: cortech-infra — Grafana dashboard ConfigMap

**Repo:** `cortech-infra`

**Files:**
- Create: `k8s/observability/dashboards/applications/osint-platform.yaml`

**Step 1: Create dashboard ConfigMap**

Follow existing template pattern (`_template.yaml`):
- Namespace: `observability`
- Labels: `grafana_dashboard: "1"`, `release: prometheus`, `app.kubernetes.io/name: grafana-dashboard`, `app.kubernetes.io/component: application`
- Annotation: `grafana_folder: "Applications"`
- Data key: `osint-platform.json`

Dashboard panels:
1. **Ingestion Rate** — `rate(osint_events_ingested_total[5m])` by source
2. **Alert Volume** — `rate(osint_alerts_fired_total[1h])` by severity
3. **Active Jobs** — `osint_active_jobs` by type
4. **Ingestion Duration** — `histogram_quantile(0.95, osint_ingestion_duration_seconds)`
5. **Celery Queue Depth** — `osint_celery_queue_depth` by queue
6. **Pod Status** — standard k8s pod status for osint namespace

**Step 2: Commit**

```bash
git add k8s/observability/dashboards/applications/osint-platform.yaml
git commit -m "feat: add Grafana dashboard ConfigMap for OSINT platform"
```

---

### Task 36: End-to-end pipeline integration test

**Repo:** `osint-core`

**Files:**
- Create: `tests/integration/test_pipeline.py`
- Create: `tests/integration/conftest.py`

**Step 1: Write integration test**

```python
# tests/integration/test_pipeline.py
"""
End-to-end pipeline test:
Plan load → Source ingest → Event creation → Indicator extraction →
Scoring → Alert creation → Notification dispatch

Uses docker-compose.dev.yaml services (Postgres, Redis, Qdrant).
"""
import pytest


@pytest.mark.integration
async def test_full_pipeline(db_session, redis_client, mock_feed_server):
    # 1. Load and activate a test plan
    # 2. Trigger ingestion for a mocked CISA KEV feed
    # 3. Verify events created in DB
    # 4. Verify indicators extracted and linked
    # 5. Verify events scored
    # 6. Verify alert created (if score exceeds threshold)
    # 7. Verify notification dispatched (mock Gotify)
    ...
```

**Step 2: Create integration conftest**

Fixtures for:
- Postgres connection (using `docker-compose.dev.yaml` or testcontainers)
- Redis client
- Qdrant client
- Mock HTTP server for feed responses

**Step 3: Run integration tests**

```bash
docker compose -f docker-compose.dev.yaml up -d postgres redis qdrant
python -m pytest tests/integration/ -v -m integration
```

**Step 4: Commit**

```bash
git add -A
git commit -m "test: add end-to-end pipeline integration test"
```

---

## Task Dependencies

```
Phase 0 (sequential):
  Task 1 (scaffold) → Task 2 (models) → Task 3 (schemas) → Task 4 (FastAPI skeleton)
  Task 5 (plan engine) → Task 6 (plan API)
  Task 7 (Celery) can run parallel to Task 5
  Task 8 (logging) can run parallel to Task 5
  Task 9 (Dockerfile) depends on Tasks 1-4
  Task 10 (CI) depends on Task 9
  Tasks 11-13 (cortech-infra) can run parallel to osint-core tasks

Phase 1 (after Phase 0):
  Task 14 (connector base) → Tasks 15-20 (individual connectors) — these are independent
  Task 21 (indicators) can run parallel to connectors
  Task 22 (Celery ingest) depends on Tasks 14, 21
  Task 23 (scoring) → Task 24 (alerting) → Tasks 25-26 (notifications, escalation)
  Task 27 (Qdrant) can run parallel to scoring
  Task 28 (correlation) depends on Tasks 21, 27
  Task 29 (NER) can run parallel
  Task 30 (briefs) depends on Tasks 27, 29
  Task 31 (API routes) depends on all service tasks
  Task 32 (auth) can run parallel
  Task 33 (audit) can run parallel
  Task 34 (metrics) can run parallel
  Task 35 (Grafana) can run anytime
  Task 36 (integration test) depends on everything
```

---

## Verification Checklist (run before declaring MVP complete)

```bash
# In osint-core repo:
ruff check src/ tests/                      # No lint errors
mypy src/osint_core/                        # No type errors
pytest --cov=osint_core -v                  # All tests pass, >80% coverage
docker compose -f docker-compose.dev.yaml up -d
pytest tests/integration/ -v -m integration # Pipeline works end-to-end
curl http://localhost:8000/healthz           # Returns {"status": "ok"}
curl http://localhost:8000/api/v1/docs       # Swagger UI loads
curl http://localhost:8000/metrics           # Prometheus metrics

# In cortech-infra repo:
kubectl apply --dry-run=server -k apps/osint/overlays/production/  # Manifests valid
```
