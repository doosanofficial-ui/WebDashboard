from __future__ import annotations

import httpx
import sys
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app


class _FakeHTTPClient:
    def __init__(self, status_code: int, body: str):
        self.status_code = status_code
        self.body = body

    async def get(self, url, **kwargs):
        return httpx.Response(
            self.status_code,
            text=self.body,
            request=httpx.Request("GET", url),
        )


class NaverErrorBoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def _call(self, status_code: int, body: str):
        old_settings = app.settings
        old_client = app.http_client
        app.settings = replace(
            old_settings,
            naver_maps_client_id="public-id",
            naver_maps_client_secret="secret-value",
        )
        app.http_client = _FakeHTTPClient(status_code, body)
        try:
            with self.assertRaises(app.HTTPException) as context:
                await app.api_naver_reverse_geocode(37.5, 127.0)
            return context.exception
        finally:
            app.settings = old_settings
            app.http_client = old_client

    async def test_auth_failure_does_not_reflect_upstream_body(self):
        error = await self._call(403, '{"message":"secret-value leaked"}')
        self.assertEqual(error.status_code, 403)
        self.assertEqual(error.detail, "reverse_geocode_auth_failed")
        self.assertNotIn("secret-value", str(error.detail))

    async def test_upstream_failure_has_stable_safe_detail(self):
        error = await self._call(500, "filesystem=/private/secret-value")
        self.assertEqual(error.status_code, 502)
        self.assertEqual(error.detail, "reverse_geocode_unavailable")
        self.assertNotIn("secret-value", str(error.detail))


if __name__ == "__main__":
    unittest.main()
