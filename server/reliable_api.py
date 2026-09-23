"""Authenticated HTTP boundary for durable telemetry batches."""
from __future__ import annotations

import asyncio
import json
import secrets
import sqlite3

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from ingest import MAX_BATCH_BYTES, IngestConflict, IngestValidationError

router = APIRouter()


def _response(content: dict, status: int = 200) -> JSONResponse:
    return JSONResponse(content, status_code=status, headers={"Cache-Control": "no-store"})


def _error(code: str, message: str, status: int) -> JSONResponse:
    return _response({"error": {"code": code, "message": message}}, status)


def _unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


@router.post("/api/v2/ingest")
async def ingest(request: Request) -> JSONResponse:
    token = getattr(request.app.state, "ingest_token", None)
    journal = getattr(request.app.state, "ingest_journal", None)
    if not token or journal is None:
        return _error("ingest_unconfigured", "Reliable ingestion is not configured", 503)
    peer = request.client.host if request.client else None
    if request.url.scheme != "https" and peer not in ("127.0.0.1", "::1"):
        return _error("https_required", "HTTPS is required for remote ingestion", 426)

    scheme, _, supplied = request.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not supplied or len(supplied) > 512 or not secrets.compare_digest(
        supplied.encode("utf-8"), token.encode("utf-8")
    ):
        return _error("unauthorized", "Valid device authorization is required", 401)

    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_BATCH_BYTES:
            return _error("body_too_large", "Request body exceeds limit", 413)
        body.extend(chunk)
    try:
        payload = json.loads(body, object_pairs_hook=_unique_fields)
    except (ValueError, UnicodeError, RecursionError):
        return _error("invalid_json", "Request must contain valid JSON with unique fields", 400)

    try:
        ack = await asyncio.to_thread(journal.ingest, payload)
    except IngestValidationError as exc:
        return _error("invalid_batch", str(exc), 422)
    except IngestConflict:
        return _error("event_conflict", "An event ID was reused with different content", 409)
    except (sqlite3.Error, OSError):
        return _error("storage_unavailable", "Durable storage is unavailable; keep events queued", 503)
    return _response(ack)
