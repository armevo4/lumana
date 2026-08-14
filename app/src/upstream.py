"""Client for the upstream public API (TMDB).

Security notes, since this service proxies user-supplied text to a third party:

  * The user controls only the value of a single query *parameter*. The scheme, host and
    path are fixed constants assembled here. At no point is user input allowed to
    influence the destination URL — that is the SSRF vector in any proxy of this shape.

  * The API key is never included in log output or in any error surfaced to the caller.
    Upstream failures are translated into a generic message; the detail stays in the
    server-side log.

  * Every upstream call is bounded by a timeout, so a slow third party cannot exhaust
    this service's connection pool.
"""

from __future__ import annotations

import logging

import httpx

from .config import settings

log = logging.getLogger(__name__)

MAX_QUERY_LENGTH = 200


class UpstreamError(RuntimeError):
    """The upstream API could not be reached or returned an error."""


class InvalidQuery(ValueError):
    """The caller's query failed validation."""


def validate_query(raw: str) -> str:
    """Normalise and bound a user-supplied search term."""
    query = raw.strip()
    if not query:
        raise InvalidQuery("query must not be empty")
    if len(query) > MAX_QUERY_LENGTH:
        raise InvalidQuery(f"query must be at most {MAX_QUERY_LENGTH} characters")
    # Reject control characters outright rather than trying to sanitise them.
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in query):
        raise InvalidQuery("query must not contain control characters")
    return query


class UpstreamClient:
    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None

    async def start(self) -> None:
        self._client = httpx.AsyncClient(
            base_url=settings.tmdb_base_url,
            timeout=settings.upstream_timeout_seconds,
        )

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    async def search(self, query: str) -> dict:
        """Search the upstream API for a validated text query."""
        if self._client is None:
            raise UpstreamError("upstream client not started")
        if not settings.tmdb_api_key:
            raise UpstreamError("upstream API key is not configured")

        try:
            # Fixed path; user input travels only in the `query` parameter, which httpx
            # percent-encodes.
            response = await self._client.get(
                "/search/movie",
                params={
                    "api_key": settings.tmdb_api_key,
                    "query": query,
                    "include_adult": "false",
                },
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            # Log the status but not the URL: the URL contains the API key.
            log.error("upstream returned HTTP %s", exc.response.status_code)
            raise UpstreamError("upstream API request failed") from exc
        except httpx.HTTPError as exc:
            log.error("upstream request error: %s", type(exc).__name__)
            raise UpstreamError("upstream API is unreachable") from exc

        payload = response.json()
        return {
            "total_results": payload.get("total_results", 0),
            "results": [
                {
                    "id": item.get("id"),
                    "title": item.get("title"),
                    "release_date": item.get("release_date"),
                    "overview": item.get("overview"),
                    "vote_average": item.get("vote_average"),
                }
                for item in payload.get("results", [])[:10]
            ],
        }

    async def details(self, movie_id: int) -> dict:
        """Proxy a second upstream endpoint: full details for one movie.

        The path segment is built from an int that FastAPI has already validated, so user
        input still cannot alter the shape of the upstream URL.
        """
        if self._client is None:
            raise UpstreamError("upstream client not started")
        if not settings.tmdb_api_key:
            raise UpstreamError("upstream API key is not configured")

        try:
            response = await self._client.get(
                f"/movie/{int(movie_id)}",
                params={"api_key": settings.tmdb_api_key},
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404:
                raise UpstreamError("movie not found") from exc
            log.error("upstream returned HTTP %s", exc.response.status_code)
            raise UpstreamError("upstream API request failed") from exc
        except httpx.HTTPError as exc:
            log.error("upstream request error: %s", type(exc).__name__)
            raise UpstreamError("upstream API is unreachable") from exc

        payload = response.json()
        return {
            "id": payload.get("id"),
            "title": payload.get("title"),
            "release_date": payload.get("release_date"),
            "runtime": payload.get("runtime"),
            "overview": payload.get("overview"),
            "vote_average": payload.get("vote_average"),
            "genres": [g.get("name") for g in payload.get("genres", [])],
        }


upstream = UpstreamClient()
