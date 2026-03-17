# =============================================================================
# Stage 1 — Builder
# Purpose: install Python dependencies with build tools present.
#          Build tools (gcc, musl-dev) are NOT copied to the final image,
#          which keeps the attack surface and image size minimal.
# =============================================================================
FROM python:3.12-alpine AS builder

# WORKDIR creates the directory if absent and sets it as CWD for all
# subsequent RUN / COPY / CMD instructions.
WORKDIR /app

# Install OS-level build dependencies needed only at compile time
# (some wheels must compile C extensions against musl libc).
# --no-cache avoids writing the apk index to disk → smaller layer.
RUN apk add --no-cache gcc musl-dev libffi-dev

# Copy the dependency manifest BEFORE the source code.
# Docker caches each layer; if requirements.txt hasn't changed, the
# expensive `pip install` layer is reused even when source files change.
COPY app/requirements.txt .

# Install packages into /install so we can `COPY --from=builder` just
# the installed files without dragging gcc/musl into the runtime image.
# --no-cache-dir keeps the pip cache out of the layer.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# =============================================================================
# Stage 2 — Final (runtime image)
# Starts from a clean alpine image — no compiler, no pip cache, no build
# artifacts. Only the application code and its installed dependencies land here.
# =============================================================================
FROM python:3.12-alpine AS final

# Create a non-root system user and group.
# Running as root inside a container is a CIS Docker Benchmark violation and
# can allow container-escape exploits to reach the host as root.
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy the pre-built packages from Stage 1.
# /usr/local is Python's default sys.prefix, so packages are immediately
# importable without modifying PYTHONPATH.
COPY --from=builder /install /usr/local

# Copy application source code.
# Doing this AFTER the dependency copy means source-only changes still
# hit the cache for the heavier dependency layer.
COPY app/ .

# Hand ownership of all app files to the non-root user.
RUN chown -R appuser:appgroup /app

# Drop privileges — all subsequent instructions and the container process
# run as appuser (UID determined at adduser time, non-zero).
USER appuser

# Document the port the application listens on (informational; does not
# publish it — that is done with `docker run -p` or in compose/K8s).
EXPOSE 5000

# HEALTHCHECK lets the Docker daemon (and orchestrators) know whether the
# container is actually serving traffic, not just running a process.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:5000/health || exit 1

# Runtime environment variables
# PYTHONDONTWRITEBYTECODE — skip .pyc files (unnecessary in containers).
# PYTHONUNBUFFERED      — flush stdout/stderr immediately (visible in logs).
ENV FLASK_ENV=production \
    PORT=5000 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Use gunicorn (production WSGI server) instead of Flask's dev server.
# --workers 2: rule-of-thumb is 2×CPU + 1; 2 is safe for small instances.
CMD ["python", "-m", "gunicorn", \
     "--bind", "0.0.0.0:5000", \
     "--workers", "2", \
     "--access-logfile", "-", \
     "app:app"]
