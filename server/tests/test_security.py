"""Security defaults for the browser/API boundary."""
import subprocess
import sys
import unittest
from pathlib import Path


class SecurityDefaultTests(unittest.TestCase):
    def test_default_app_does_not_install_wildcard_cors(self):
        script = r'''
from fastapi.middleware.cors import CORSMiddleware
import app
assert not any(m.cls is CORSMiddleware for m in app.app.user_middleware), "wildcard CORS is enabled by default"
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_explicit_origin_is_allowlisted_without_wildcard(self):
        script = r'''
import os
os.environ["ALLOWED_ORIGINS"] = "https://ops.example, https://localhost:9443"
from fastapi.testclient import TestClient
from app import app
with TestClient(app) as client:
    response = client.options("/api/ping", headers={
        "Origin": "https://ops.example",
        "Access-Control-Request-Method": "GET",
    })
    assert response.headers.get("access-control-allow-origin") == "https://ops.example"
    assert response.headers.get("access-control-allow-credentials") == "true"
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
