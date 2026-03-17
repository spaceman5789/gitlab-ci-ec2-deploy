# Flask REST API — Docker Containerization

A production-ready Python Flask REST API demonstrating Docker best practices:
multi-stage builds, non-root user, minimal Alpine base image, and a full
GitLab CI/CD pipeline that pushes to Docker Hub (and optionally AWS ECR).

---

## Project structure

```text
.
├── app/
│   ├── app.py               # Flask REST API (items CRUD + health)
│   ├── requirements.txt     # Runtime dependencies
│   ├── requirements-dev.txt # Dev/test dependencies
│   └── tests/
│       └── test_app.py      # pytest test suite
├── Dockerfile               # Multi-stage build (builder → final)
├── .dockerignore            # Excludes tests, caches, IDE files
├── docker-compose.yml       # One-command local stack
├── Makefile                 # Automation shortcuts
└── .gitlab-ci.yml           # CI: test → build → push (Hub + ECR)
```

---

## Quick start

### Prerequisites

- Docker ≥ 24

### Build & run

```bash
# Build
make build

# Start (detached)
make run

# Test the API
curl http://localhost:5000/health
curl http://localhost:5000/api/items
curl -X POST http://localhost:5000/api/items \
     -H "Content-Type: application/json" \
     -d '{"name":"widget","description":"my first item"}'

# View logs
make logs

# Stop
make stop
```

### Using Docker Compose

```bash
docker compose up -d
docker compose down
```

---

## API endpoints

| Method | Path              | Description       |
|--------|-------------------|-------------------|
| GET    | `/`               | Service info      |
| GET    | `/health`         | Health check      |
| GET    | `/api/items`      | List all items    |
| POST   | `/api/items`      | Create an item    |
| GET    | `/api/items/<id>` | Get item by ID    |
| DELETE | `/api/items/<id>` | Delete item by ID |

---

## Image size comparison

The table below documents the impact of each optimisation step.
All measurements use the same application code and dependencies.

| Base image                   | Strategy              | Approx. size | Notes                                    |
|------------------------------|-----------------------|:------------:|------------------------------------------|
| `python:3.12`                | Single-stage (Debian) |  ~1 050 MB   | Default; ships with gcc, pip cache, docs |
| `python:3.12-slim`           | Single-stage (slim)   |   ~ 200 MB   | Strips most OS packages; still Debian    |
| `python:3.12-alpine`         | Single-stage (Alpine) |   ~  75 MB   | musl libc; smallest usable base          |
| `python:3.12-alpine` (final) | **Multi-stage**       |   ~  55 MB   | Build tools absent; only runtime files   |

To reproduce locally after building:

```bash
docker image inspect flask-api:latest \
  --format '{{printf "%.1f MB" (divf .Size 1048576)}}'
```

### Why multi-stage wins

A single-stage Alpine build still contains:

- `gcc`, `musl-dev`, `libffi-dev` (needed only to compile wheels)
- The `pip` download cache

Multi-stage: Stage 1 installs everything; Stage 2 copies only the installed
packages (`/install`) and application source. Build toolchain never lands in
the final image → smaller attack surface + smaller push/pull.

---

## Dockerfile — line-by-line explanation

```dockerfile
# ── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM python:3.12-alpine AS builder
```

`AS builder` names the stage so Stage 2 can reference it with `COPY --from=builder`.
Alpine is chosen because it ships a minimal OS (~5 MB) compared to Debian (~80 MB).

```dockerfile
WORKDIR /app
```

Creates `/app` and sets it as the CWD. Avoids relative-path bugs; cleaner than
prefixing every path manually.

```dockerfile
RUN apk add --no-cache gcc musl-dev libffi-dev
```

Some Python wheels (e.g. cryptography) compile C code at install time.
`--no-cache` skips writing the apk package index to disk, preventing an extra
cache layer.

```dockerfile
COPY app/requirements.txt .
```

Copies **only** the dependency manifest first. Docker caches each layer; if
`requirements.txt` hasn't changed, the expensive `pip install` layer is reused
even when application source changes.

```dockerfile
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
```

`--prefix=/install` installs to a custom path so we can copy just the
packages to Stage 2 without gcc or musl-dev tagging along.
`--no-cache-dir` keeps pip's download cache out of this layer.

```dockerfile
# ── Stage 2: Final ───────────────────────────────────────────────────────────
FROM python:3.12-alpine AS final
```

Starts a **brand-new layer graph** from a clean Alpine image. Nothing from
Stage 1 (gcc, pip cache, source tree) exists here unless explicitly copied.

```dockerfile
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
```

Creates a system user with no password and no login shell.
Running as root inside a container can allow container-escape exploits to
reach the host with root privileges — a CIS Docker Benchmark violation.

```dockerfile
WORKDIR /app
```

Sets the working directory for subsequent instructions and the final CMD.

```dockerfile
COPY --from=builder /install /usr/local
```

Copies the pre-built Python packages from Stage 1.
`/usr/local` is Python's default `sys.prefix`, so packages are immediately
importable without touching `PYTHONPATH`.

```dockerfile
COPY app/ .
```

Copies application source **after** the dependency layer. Source-only changes
still benefit from the cached dependency layer above.

```dockerfile
RUN chown -R appuser:appgroup /app
USER appuser
```

Transfers ownership before switching users (can't `chown` after dropping root).
All subsequent instructions and the running process use `appuser`.

```dockerfile
EXPOSE 5000
```

Documents the port. Does **not** publish it — that requires `-p 5000:5000`
at `docker run` time (or `ports:` in Compose).

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:5000/health || exit 1
```

Lets the Docker daemon (and orchestrators like ECS/K8s) determine whether
the container is actually serving traffic. A container can be `Up` but
unhealthy if the app crashed internally.

```dockerfile
ENV FLASK_ENV=production \
    PORT=5000 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
```

`PYTHONDONTWRITEBYTECODE` — skip `.pyc` files (unnecessary in containers).
`PYTHONUNBUFFERED` — flush stdout/stderr immediately so logs appear in `docker logs`.

```dockerfile
CMD ["python", "-m", "gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", \
     "--access-logfile", "-", "app:app"]
```

Uses **gunicorn** instead of Flask's built-in dev server.
`--access-logfile -` routes access logs to stdout so they're captured by
`docker logs` and any log aggregator attached to the container.

---

## GitLab CI/CD pipeline

```text
test  →  build  →  push-docker-hub  (main only)
                →  push-ecr          (main, manual)
```

### Required CI/CD variables

Go to **Settings → CI/CD → Variables** and add:

| Variable               | Required for   | Notes                            |
|------------------------|----------------|----------------------------------|
| `DOCKER_HUB_USERNAME`  | Docker Hub     | Your Hub login name              |
| `DOCKER_HUB_TOKEN`     | Docker Hub     | Hub access token (masked)        |
| `AWS_ACCOUNT_ID`       | ECR (optional) | 12-digit account number          |
| `AWS_DEFAULT_REGION`   | ECR (optional) | e.g. `us-east-1`                 |
| `AWS_ACCESS_KEY_ID`    | ECR (optional) | IAM key with ECR push permission |
| `AWS_SECRET_ACCESS_KEY`| ECR (optional) | (masked, protected)              |

### Pipeline stages

**test** — installs dev dependencies, runs `pytest` with coverage report.

**build** — uses Docker-in-Docker to build the image and print its size.
Verifies the multi-stage build produces a working image on every commit.

**push-docker-hub** — builds and pushes three tags to Docker Hub:

- `:latest`
- `:<commit-sha>` — full traceability, safe to deploy by pinning SHA
- `:<branch-slug>` — e.g. `:main`

**push-ecr** *(manual, opt-in)* — pushes the same image to AWS ECR.
Won't block the pipeline if skipped; useful for AWS-based deployments.

---

## Makefile targets

```text
make help            Show all targets
make build           Build image (with cache)
make build-no-cache  Build from scratch
make run             Start container on :5000
make run-dev         Interactive with source mounted
make stop            Stop and remove container
make restart         stop + run
make logs            Tail live logs
make shell           /bin/sh inside container
make inspect         Image size + layer breakdown
make test            pytest inside container
make push            Push to Docker Hub
make clean           Remove local image
make prune           docker system prune -f
```

---

## Pushing to Docker Hub manually

```bash
# Login once
docker login -u YOUR_USERNAME

# Build
make build

# Push
DOCKER_HUB_USERNAME=YOUR_USERNAME make push
```

---

## Technologies

| Tool         | Version  | Role                   |
|--------------|----------|------------------------|
| Python       | 3.12     | Runtime                |
| Flask        | 3.1      | Web framework          |
| Gunicorn     | 23       | Production WSGI server |
| Docker       | ≥ 24     | Containerisation       |
| Alpine Linux | 3.x      | Minimal base OS        |
| GitLab CI    | —        | CI/CD pipeline         |
| Docker Hub   | —        | Public image registry  |
| AWS ECR      | optional | Private image registry |
| pytest       | 8        | Test framework         |
