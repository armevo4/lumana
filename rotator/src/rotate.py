"""Rotate MongoDB application credentials, then publish them to a Kubernetes Secret.

Run once per minute by a Kubernetes CronJob.

The design is a two-user alternation. Two application users exist — `app_a` and `app_b`
— and each run rotates whichever one is *not* currently in use, then points the Secret at
it:

    run N     : app_a active. Give app_b a fresh password. Secret -> app_b.
    run N+1   : app_b active. Give app_a a fresh password. Secret -> app_a.

The consequence is that any credential published to the Secret stays valid for two full
cycles — roughly two minutes — before it is rotated again.

That overlap is what makes the whole thing safe. A mounted Secret can take up to ~60
seconds to propagate to a pod, and the schedule here is also 60 seconds, so propagation
and rotation are racing. Rotating the *inactive* user means a pod that has not yet
noticed the change is still holding a credential that works.

Order of operations matters:

    1. Update the inactive user's password in MongoDB.
    2. Verify by authenticating as that user. If this fails, abort WITHOUT touching the
       Secret — pods keep using the previous credential, which is still valid.
    3. Only then patch the Secret.

Publishing a credential before proving it works would be the one way this design could
cause an outage, so it is deliberately the last step.
"""

from __future__ import annotations

import base64
import logging
import os
import secrets
import sys
from urllib.parse import quote_plus

from kubernetes import client, config
from pymongo import MongoClient
from pymongo.errors import OperationFailure, PyMongoError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s rotator: %(message)s",
)
log = logging.getLogger(__name__)

APP_USERS = ("app_a", "app_b")
PASSWORD_BYTES = 32
REQUEST_TIMEOUT_SECONDS = 10


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None:
        log.error("required environment variable %s is not set", name)
        sys.exit(1)
    return value


def decode(secret_data: dict, key: str) -> str | None:
    raw = secret_data.get(key) if secret_data else None
    return base64.b64decode(raw).decode().strip() if raw else None


def next_user(current: str | None) -> str:
    """Pick the user that is NOT currently active."""
    if current not in APP_USERS:
        # First run, or the Secret holds something unexpected. Start at the beginning.
        return APP_USERS[0]
    return APP_USERS[1] if current == APP_USERS[0] else APP_USERS[0]


def set_password(admin: MongoClient, database: str, username: str, password: str) -> None:
    """Set the user's password, creating the user on first run."""
    db = admin[database]
    try:
        db.command("updateUser", username, pwd=password)
        log.info("updated password for existing user %s", username)
    except OperationFailure as exc:
        # UserNotFound (code 11) — this is the first rotation, so create the user.
        if exc.code != 11:
            raise
        db.command(
            "createUser",
            username,
            pwd=password,
            roles=[{"role": "readWrite", "db": database}],
        )
        log.info("created user %s", username)


def verify(host: str, port: str, database: str, username: str, password: str) -> None:
    """Prove the new credential actually authenticates before publishing it."""
    uri = (
        f"mongodb://{quote_plus(username)}:{quote_plus(password)}@{host}:{port}"
        f"/{database}?authSource={database}"
    )
    probe = MongoClient(uri, serverSelectionTimeoutMS=5000)
    try:
        probe.admin.command("ping")
        log.info("verified new credential for %s", username)
    finally:
        probe.close()


def publish(
    core: client.CoreV1Api,
    namespace: str,
    secret_name: str,
    username: str,
    password: str,
) -> None:
    """Patch the Kubernetes Secret that application pods have mounted.

    Takes an existing API client rather than constructing one. Every bare
    `client.CoreV1Api()` builds its own ApiClient with its own thread pool, and those
    threads keep the interpreter alive after main() returns — a short-lived Job then
    hangs until the CronJob's activeDeadlineSeconds kills it, having done its work but
    never reporting success.
    """
    core.patch_namespaced_secret(
        name=secret_name,
        namespace=namespace,
        body={
            "data": {
                "username": base64.b64encode(username.encode()).decode(),
                "password": base64.b64encode(password.encode()).decode(),
            }
        },
        # Never block indefinitely. A rotator that hangs stops rotating silently, which
        # is the worst failure mode available to it.
        _request_timeout=REQUEST_TIMEOUT_SECONDS,
    )
    log.info("patched secret %s/%s -> %s", namespace, secret_name, username)


def main() -> int:
    namespace = env("ROTATOR_NAMESPACE")
    secret_name = env("ROTATOR_SECRET_NAME")
    mongo_host = env("ROTATOR_MONGO_HOST")
    mongo_port = env("ROTATOR_MONGO_PORT", "27017")
    database = env("ROTATOR_MONGO_DATABASE")
    admin_user = env("ROTATOR_MONGO_ADMIN_USER")
    admin_password = env("ROTATOR_MONGO_ADMIN_PASSWORD")

    config.load_incluster_config()

    # Context-managed so the ApiClient's thread pool is shut down. Without this the
    # interpreter stays alive after main() returns and the Job never completes.
    with client.ApiClient() as api_client:
        core = client.CoreV1Api(api_client)

        existing = core.read_namespaced_secret(
            name=secret_name,
            namespace=namespace,
            _request_timeout=REQUEST_TIMEOUT_SECONDS,
        )
        current_user = decode(existing.data, "username")
        target_user = next_user(current_user)
        log.info("active user is %s, rotating %s", current_user or "<unset>", target_user)

        new_password = secrets.token_urlsafe(PASSWORD_BYTES)

        admin_uri = (
            f"mongodb://{quote_plus(admin_user)}:{quote_plus(admin_password)}"
            f"@{mongo_host}:{mongo_port}/?authSource=admin"
        )
        admin = MongoClient(admin_uri, serverSelectionTimeoutMS=5000)

        try:
            set_password(admin, database, target_user, new_password)
            verify(mongo_host, mongo_port, database, target_user, new_password)
        except PyMongoError:
            # Abort without publishing. Pods keep the previous credential, which is
            # still valid for another cycle, so nothing breaks.
            log.exception("rotation failed before publishing; secret left unchanged")
            return 1
        finally:
            admin.close()

        publish(core, namespace, secret_name, target_user, new_password)

    log.info("rotation complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
