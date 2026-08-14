"""MongoDB connection management with zero-downtime credential rotation.

The rotation sequence, and why each step is in this order:

    1. Build a NEW client using the new credentials. The old client is untouched and
       keeps serving traffic throughout.
    2. Ping the new client. If the new credential is bad — the rotator failed halfway,
       the Secret propagated before the database user was updated — we find out here,
       abandon the new client, and keep serving on the old one. Nothing breaks.
    3. Only after a successful ping, swap the active reference. Rebinding an attribute
       is atomic under the GIL, so no request can observe a half-swapped state.
    4. Close the old client after a drain delay, letting in-flight queries finish.

Because the active client is only ever replaced by a verified-working one, readiness
never flaps. That matters more than it sounds: if `/readyz` failed during a swap, the
Service would remove the pod from its endpoints and clients would see 503s — which is
precisely the downtime this design exists to avoid.

See docs/DECISIONS.md section 5.
"""

from __future__ import annotations

import asyncio
import logging
from urllib.parse import quote_plus

from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase

from .config import settings
from .credentials import Credentials

log = logging.getLogger(__name__)

CACHE_COLLECTION = "search_cache"
HISTORY_COLLECTION = "query_history"


def build_uri(creds: Credentials) -> str:
    """Assemble the connection URL from ConfigMap-supplied host details and the
    Secret-supplied credentials.

    Credentials are percent-encoded: rotated passwords are randomly generated and may
    contain characters that would otherwise corrupt the URI.
    """
    return settings.mongo_uri_template.format(
        username=quote_plus(creds.username),
        password=quote_plus(creds.password),
    )


class MongoManager:
    """Owns the active MongoDB client and swaps it in place on rotation."""

    def __init__(self) -> None:
        self._client: AsyncIOMotorClient | None = None
        self._credentials: Credentials | None = None
        self._rotation_count = 0
        self._lock = asyncio.Lock()

    @property
    def database(self) -> AsyncIOMotorDatabase:
        if self._client is None:
            raise RuntimeError("MongoManager.connect() has not been called")
        return self._client[settings.mongo_database]

    @property
    def rotation_count(self) -> int:
        return self._rotation_count

    @property
    def active_username(self) -> str | None:
        return self._credentials.username if self._credentials else None

    @staticmethod
    def _new_client(creds: Credentials) -> AsyncIOMotorClient:
        return AsyncIOMotorClient(
            build_uri(creds),
            serverSelectionTimeoutMS=5000,
            connectTimeoutMS=5000,
            # Keep a warm pool so a rotation does not cause a thundering herd of
            # reconnects when the new client takes over.
            minPoolSize=2,
            maxPoolSize=20,
        )

    async def connect(self, creds: Credentials) -> None:
        """Establish the initial connection and ensure indexes exist."""
        client = self._new_client(creds)
        await client.admin.command("ping")
        self._client = client
        self._credentials = creds
        log.info("connected to mongodb as %s", creds.redacted())
        await self._ensure_indexes()

    async def rotate(self, creds: Credentials) -> None:
        """Swap in a new client built from rotated credentials, with no downtime."""
        async with self._lock:
            candidate = self._new_client(creds)
            try:
                await candidate.admin.command("ping")
            except Exception:
                # The new credential does not work yet. Abandon it and keep serving on
                # the existing client; the watcher will retry on the next poll.
                candidate.close()
                raise

            previous = self._client
            previous_creds = self._credentials

            # Atomic swap. From here on, new requests use the new client.
            self._client = candidate
            self._credentials = creds
            self._rotation_count += 1

            log.info(
                "rotated mongodb client %s -> %s (rotation #%d)",
                previous_creds.redacted() if previous_creds else "none",
                creds.redacted(),
                self._rotation_count,
            )

        if previous is not None:
            asyncio.create_task(self._drain(previous, settings.client_drain_seconds))

    @staticmethod
    async def _drain(client: AsyncIOMotorClient, delay: float) -> None:
        """Close a superseded client once its in-flight queries have finished."""
        await asyncio.sleep(delay)
        client.close()
        log.debug("closed superseded mongodb client after %.0fs drain", delay)

    async def ping(self) -> None:
        """Liveness check against the currently active client. Used by /readyz."""
        if self._client is None:
            raise RuntimeError("not connected")
        await self._client.admin.command("ping")

    async def _ensure_indexes(self) -> None:
        db = self.database
        # TTL index: cached upstream responses expire on their own, so the cache never
        # grows without bound and stale results are not served indefinitely.
        await db[CACHE_COLLECTION].create_index(
            "created_at", expireAfterSeconds=settings.cache_ttl_seconds
        )
        await db[CACHE_COLLECTION].create_index("query", unique=True)
        await db[HISTORY_COLLECTION].create_index("requested_at")
        log.info("mongodb indexes ensured")

    async def close(self) -> None:
        if self._client is not None:
            self._client.close()
            self._client = None


mongo = MongoManager()
