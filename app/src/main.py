"""FastAPI application: a caching proxy in front of a public text-search API.

Request flow for /search:

    client -> validate query -> MongoDB cache lookup
                                     |hit  -> return cached payload
                                     |miss -> call upstream API
                                              -> store in cache (TTL indexed)
                                              -> record in query history
                                              -> return payload

The database is deliberately on the hot path. A database that merely sits alongside the
application would prove nothing during a credential rotation; because every request
reads and most requests write, the load test genuinely exercises the rotated connection.
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

from . import credentials as creds_module
from .config import settings
from .db import CACHE_COLLECTION, HISTORY_COLLECTION, mongo
from .upstream import InvalidQuery, UpstreamError, upstream, validate_query

logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
)
log = logging.getLogger("app")


async def _connect_and_watch() -> None:
    """Connect to MongoDB with retry, then watch for credential rotations.

    This runs as a background task rather than blocking startup, and that is a
    deliberate correctness decision rather than a nicety.

    On a fresh cluster the application starts before the rotator has run, so the
    published credential is still a placeholder and authentication fails. If startup
    blocked on the database, the process would exit, the HTTP server would never bind,
    and both probes would fail on connection-refused — so the kubelet would restart the
    pod in a CrashLoopBackOff whose backoff grows to minutes, long outlasting the
    problem itself.

    Instead the server binds immediately and reports liveness (the process is healthy)
    while readiness stays false (it cannot serve yet). No restarts happen, and the pod
    joins the Service the instant the database becomes reachable. This is the same
    behaviour that protects against a MongoDB restart at any other time.
    """
    delay = 2.0
    creds = None
    while True:
        try:
            creds = creds_module.read_credentials(settings.mongo_credentials_dir)
            await mongo.connect(creds)
            break
        except Exception as exc:
            log.warning(
                "database not ready (%s: %s); retrying in %.0fs",
                type(exc).__name__,
                exc,
                delay,
            )
            await asyncio.sleep(delay)
            delay = min(delay * 2, 15.0)

    log.info("credential watcher started (%s)", settings.mongo_credentials_dir)
    await creds_module.watch(
        directory=settings.mongo_credentials_dir,
        poll_seconds=settings.credentials_poll_seconds,
        current=creds,
        on_change=mongo.rotate,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    await upstream.start()
    bootstrap = asyncio.create_task(_connect_and_watch())

    try:
        yield
    finally:
        bootstrap.cancel()
        try:
            await bootstrap
        except asyncio.CancelledError:
            pass
        await upstream.close()
        await mongo.close()
        log.info("shutdown complete")


def require_database():
    """Return the active database, or 503 if the connection is not established yet."""
    try:
        return mongo.database
    except RuntimeError as exc:
        raise HTTPException(
            status_code=503, detail="database connection not established yet"
        ) from exc


app = FastAPI(
    title="Lumana API Proxy",
    description="Caching proxy over a public text-search API, with zero-downtime "
    "database credential rotation.",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/")
async def root() -> dict:
    return {
        "service": "lumana-api-proxy",
        "environment": settings.environment,
        "endpoints": [
            "/search?q=",
            "/movie/{id}",
            "/history",
            "/healthz",
            "/readyz",
            "/rotation",
        ],
    }


@app.get("/healthz")
async def healthz() -> dict:
    """Liveness. Deliberately does NOT touch the database.

    Liveness failure kills the pod. If this probe checked MongoDB, a brief database
    outage would restart every replica at once and turn a recoverable blip into a
    cascading failure. Database health belongs in readiness, below.
    """
    return {"status": "alive"}


@app.get("/readyz")
async def readyz() -> JSONResponse:
    """Readiness. Checks the *currently active* database client.

    During a credential rotation this keeps reporting ready, because the active client
    is only ever replaced by one that has already been verified with a ping.
    """
    try:
        await mongo.ping()
    except Exception as exc:
        log.warning("readiness check failed: %s", type(exc).__name__)
        return JSONResponse(status_code=503, content={"status": "not ready"})
    return JSONResponse(status_code=200, content={"status": "ready"})


@app.get("/rotation")
async def rotation_status() -> dict:
    """Observability for the rotation demo: which credential is in use right now."""
    return {
        "active_username": mongo.active_username,
        "rotations_applied": mongo.rotation_count,
    }


@app.get("/search")
async def search(q: str = Query(..., description="Free-text search term")) -> dict:
    try:
        query = validate_query(q)
    except InvalidQuery as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    db = require_database()
    cached = await db[CACHE_COLLECTION].find_one({"query": query}, {"_id": 0})

    if cached is not None:
        payload, source = cached["payload"], "cache"
    else:
        try:
            payload = await upstream.search(query)
        except UpstreamError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

        # upsert rather than insert: concurrent identical queries would otherwise
        # collide on the unique index.
        await db[CACHE_COLLECTION].update_one(
            {"query": query},
            {"$set": {"payload": payload, "created_at": datetime.now(timezone.utc)}},
            upsert=True,
        )
        source = "upstream"

    await db[HISTORY_COLLECTION].insert_one(
        {
            "query": query,
            "source": source,
            "requested_at": datetime.now(timezone.utc),
        }
    )

    return {"query": query, "source": source, **payload}


@app.get("/movie/{movie_id}")
async def movie_details(movie_id: int) -> dict:
    """Second proxied upstream endpoint, cached the same way as /search."""
    db = require_database()
    cache_key = f"movie:{movie_id}"

    cached = await db[CACHE_COLLECTION].find_one({"query": cache_key}, {"_id": 0})
    if cached is not None:
        return {"source": "cache", **cached["payload"]}

    try:
        payload = await upstream.details(movie_id)
    except UpstreamError as exc:
        status = 404 if "not found" in str(exc) else 502
        raise HTTPException(status_code=status, detail=str(exc)) from exc

    await db[CACHE_COLLECTION].update_one(
        {"query": cache_key},
        {"$set": {"payload": payload, "created_at": datetime.now(timezone.utc)}},
        upsert=True,
    )
    return {"source": "upstream", **payload}


@app.get("/history")
async def history(limit: int = Query(20, ge=1, le=100)) -> dict:
    cursor = (
        require_database()[HISTORY_COLLECTION]
        .find({}, {"_id": 0})
        .sort("requested_at", -1)
        .limit(limit)
    )
    return {"items": await cursor.to_list(length=limit)}
