FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.12-slim

RUN groupadd --gid 10002 rotator \
    && useradd --uid 10002 --gid rotator --no-create-home --shell /usr/sbin/nologin rotator

COPY --from=builder /install /usr/local

WORKDIR /app
COPY --chown=root:root src/ ./src/

USER 10002:10002

CMD ["python", "-m", "src.rotate"]
