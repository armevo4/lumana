"""Watches the mounted credential Secret for rotation.

The kubelet updates a mounted Secret by writing a new timestamped directory and then
atomically swapping a `..data` symlink to point at it. Two consequences follow:

  1. An inotify watch on the individual credential *file* will never fire, because the
     file itself is never modified — only the symlink above it moves. A naive
     implementation that watches the file appears to work locally and silently fails in
     Kubernetes.

  2. Propagation is not instant. The kubelet refreshes mounted Secrets on its sync loop,
     which can take up to ~60 seconds.

This module therefore polls: it re-reads the credential files on a short interval and
compares values. Polling is immune to the symlink swap entirely, costs almost nothing at
a 5 second interval, and behaves identically on kind and on GKE.

Point (2) is why the rotator keeps the previous credential valid for two full cycles.
See docs/DECISIONS.md section 5.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable

log = logging.getLogger(__name__)

USERNAME_FILE = "username"
PASSWORD_FILE = "password"


@dataclass(frozen=True)
class Credentials:
    username: str
    password: str

    def redacted(self) -> str:
        """Safe for logs. Never log the password."""
        return f"{self.username}:***"


class CredentialsUnavailable(RuntimeError):
    """The credential files are missing or empty."""


def read_credentials(directory: str) -> Credentials:
    """Read the current credentials from the mounted Secret directory."""
    base = Path(directory)
    try:
        username = (base / USERNAME_FILE).read_text().strip()
        password = (base / PASSWORD_FILE).read_text().strip()
    except OSError as exc:
        raise CredentialsUnavailable(
            f"could not read credentials from {directory}: {exc}"
        ) from exc

    if not username or not password:
        raise CredentialsUnavailable(f"credential files in {directory} are empty")

    return Credentials(username=username, password=password)


async def watch(
    directory: str,
    poll_seconds: float,
    current: Credentials,
    on_change: Callable[[Credentials], Awaitable[None]],
) -> None:
    """Poll the credential directory forever, invoking `on_change` on each rotation.

    Errors are logged and swallowed. A transient failure to read or apply new
    credentials must never kill the watcher, because the existing connection is still
    working and the next poll may well succeed.
    """
    while True:
        await asyncio.sleep(poll_seconds)
        try:
            latest = read_credentials(directory)
        except CredentialsUnavailable as exc:
            log.warning("credential read failed, keeping current connection: %s", exc)
            continue

        if latest == current:
            continue

        log.info(
            "credential rotation detected: %s -> %s",
            current.redacted(),
            latest.redacted(),
        )
        try:
            await on_change(latest)
        except Exception:
            log.exception("failed to apply rotated credentials, will retry next poll")
            continue

        current = latest
