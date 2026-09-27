from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

RELEASE_PATH = Path(__file__).resolve().parent.parent / "release.json"
_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


@dataclass(frozen=True)
class ReleaseMetadata:
    product: str
    version: str
    native_build: int
    protocol_version: int

    def public_dict(self) -> dict[str, Any]:
        return {
            "product": self.product,
            "version": self.version,
            "native_build": self.native_build,
            "protocol_version": self.protocol_version,
        }


def load_release_metadata(path: Path = RELEASE_PATH) -> ReleaseMetadata:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("release_metadata_unreadable") from exc
    if not isinstance(payload, dict):
        raise ValueError("release_metadata_must_be_object")
    if payload.get("schema_version") != 1:
        raise ValueError("release_metadata_schema_unsupported")

    product = payload.get("product")
    version = payload.get("version")
    native_build = payload.get("native_build")
    protocol_version = payload.get("protocol_version")
    if (
        not isinstance(product, str)
        or not product
        or len(product.encode("utf-8")) > 128
        or not isinstance(version, str)
        or not _VERSION_RE.fullmatch(version)
        or type(native_build) is not int
        or native_build <= 0
        or type(protocol_version) is not int
        or protocol_version <= 0
    ):
        raise ValueError("release_metadata_invalid")
    return ReleaseMetadata(product, version, native_build, protocol_version)
