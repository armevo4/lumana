# Multi-stage build: compiler toolchain and build artefacts stay out of the final image.
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.12-slim

# Run as a non-root user. Combined with readOnlyRootFilesystem and a dropped capability
# set in the Kubernetes securityContext, this satisfies the `restricted` Pod Security
# Standard.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /install /usr/local

WORKDIR /app
COPY --chown=root:root src/ ./src/

USER 10001:10001

EXPOSE 8000

# Runs src/run.py, which reads the listen port from APP_PORT. Do not hardcode --port
# here: that silently overrides configuration and makes the port un-tunable per
# environment.
#
# Exec form, not shell form, so the app is PID 1 and receives SIGTERM directly — it can
# then shut down gracefully within the pod's termination grace period.
CMD ["python", "-m", "src.run"]
