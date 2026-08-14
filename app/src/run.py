"""Entrypoint.

Exists so the listen port comes from configuration rather than being baked into the
image. The Dockerfile previously invoked `uvicorn --port 8000`, which meant APP_PORT was
silently ignored and the port could not be varied per environment — exactly what the
Kustomize overlays are supposed to control.
"""

import uvicorn

from .config import settings

if __name__ == "__main__":
    uvicorn.run(
        "src.main:app",
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level.lower(),
        access_log=True,
    )
