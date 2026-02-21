from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CLIENT_DIR = BASE_DIR.parent / "client"


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    can_hz: float
    simulate_drop_every: int
    can_source: str
    log_dir: Path
    ssl_certfile: str | None
    ssl_keyfile: str | None
    naver_maps_client_id: str | None
    naver_maps_client_secret: str | None


def _optional_env(name: str) -> str | None:
    value = os.getenv(name)
    return value if value else None


def load_settings() -> Settings:
    return Settings(
        # Conservative default: loopback only.
        # Expose to other devices only when HOST is explicitly set (e.g. 0.0.0.0 or LAN IP).
        host=os.getenv("HOST", "127.0.0.1"),
        port=int(os.getenv("PORT", "8080")),
        can_hz=float(os.getenv("CAN_HZ", "10")),
        simulate_drop_every=int(os.getenv("SIM_DROP_EVERY", "0")),
        can_source=os.getenv("CAN_SOURCE", "dummy"),
        log_dir=BASE_DIR / "logs",
        ssl_certfile=_optional_env("SSL_CERTFILE"),
        ssl_keyfile=_optional_env("SSL_KEYFILE"),
        naver_maps_client_id=_optional_env("NAVER_MAPS_CLIENT_ID"),
        naver_maps_client_secret=_optional_env("NAVER_MAPS_CLIENT_SECRET"),
    )


settings = load_settings()
