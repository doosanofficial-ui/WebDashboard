from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import ReleaseMetadata, load_release_metadata


class ReleaseIdentityTests(unittest.TestCase):
    def test_repository_release_metadata_is_valid_and_public(self):
        metadata = load_release_metadata()
        self.assertEqual(metadata.product, "Telemetry")
        self.assertEqual(metadata.version, "0.21.0")
        self.assertEqual(metadata.native_build, 13)
        self.assertEqual(metadata.protocol_version, 1)
        self.assertEqual(
            metadata.public_dict(),
            {
                "product": "Telemetry",
                "version": "0.21.0",
                "native_build": 13,
                "protocol_version": 1,
            },
        )

    def test_invalid_release_metadata_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "release.json"
            path.write_text(json.dumps({"product": "Telemetry", "version": "latest"}), encoding="utf-8")
            with self.assertRaises(ValueError):
                load_release_metadata(path)

    def test_public_projection_never_contains_unknown_secret_fields(self):
        metadata = ReleaseMetadata(
            product="Telemetry",
            version="0.21.0",
            native_build=13,
            protocol_version=1,
        )
        self.assertNotIn("secret", metadata.public_dict())


if __name__ == "__main__":
    unittest.main()
