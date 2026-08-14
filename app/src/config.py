"""Application configuration.

Configuration arrives from two distinct places, and the split is deliberate:

  * Environment variables carry everything that does NOT rotate — host, port, database
    name, the upstream base URL. These come from a ConfigMap that Kustomize varies per
    overlay, which is how ports and connection URLs are controlled per environment.

  * A mounted Secret directory carries the database credentials, which DO rotate. They
    are deliberately not environment variables: env vars are frozen when the process
    starts and cannot be changed without a restart.

See docs/DECISIONS.md section 6.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_", extra="ignore")

    # --- server ---
    host: str = "0.0.0.0"
    port: int = 8000
    log_level: str = "INFO"
    environment: str = "local"

    # --- mongodb (non-secret parts only) ---
    mongo_host: str = "mongodb"
    mongo_port: int = 27017
    mongo_database: str = "lumana"
    mongo_auth_source: str = "admin"
    # Directory where the rotating credential Secret is mounted.
    mongo_credentials_dir: str = "/etc/mongo-credentials"
    # How often to re-read the credential files, in seconds.
    credentials_poll_seconds: float = 5.0
    # How long to keep a superseded client open so in-flight queries can finish.
    client_drain_seconds: float = 30.0

    # --- upstream API ---
    # The API key does not rotate, so an environment variable (from a Secret via
    # secretKeyRef) is appropriate here. Contrast with the database credentials above.
    tmdb_api_key: str = ""
    tmdb_base_url: str = "https://api.themoviedb.org/3"
    upstream_timeout_seconds: float = 5.0

    # --- cache ---
    cache_ttl_seconds: int = 300

    @property
    def mongo_uri_template(self) -> str:
        """Connection URL with credential placeholders.

        Credentials are injected at connect time from the mounted Secret rather than
        being baked in here, so that a rotation does not require rebuilding config.
        """
        return (
            f"mongodb://{{username}}:{{password}}@{self.mongo_host}:{self.mongo_port}"
            f"/{self.mongo_database}?authSource={self.mongo_auth_source}"
        )


settings = Settings()
