from __future__ import annotations

import asyncio
import logging
import math
import time
from contextlib import AsyncExitStack, asynccontextmanager, suppress
from typing import Any

import httpx
import anyio
import uvicorn
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from can_source import create_can_source
from can_source.base import CANSource
from config import CLIENT_DIR, settings
from recording import AsyncCsvRecorder
from ingest import TelemetryJournal
from reliable_api import router as reliable_router
from signal_mapper import SignalMapper
from stream import StreamPeer
from uplink import MAX_UPLINK_BYTES, UplinkError, decode_uplink

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
log = logging.getLogger("telemetry-server")

can_source: CANSource | None = None
signal_mapper: SignalMapper | None = None
logger: AsyncCsvRecorder | None = None

clients: set[StreamPeer] = set()

broadcast_task: asyncio.Task[None] | None = None
recording_task: asyncio.Task[None] | None = None
http_client: httpx.AsyncClient | None = None
stream_state: dict[str, Any] = {"seq": 0, "drop": 0, "error": None, "last_frame": None}
stream_ready: asyncio.Event | None = None


def _fail_stream(code: str) -> None:
    stream_state["error"] = code
    if stream_ready:
        stream_ready.set()
    log.error("CAN capture stopped: %s", code)


async def _sleep_until(target: float) -> None:
    delay = target - time.perf_counter()
    if delay > 0:
        await asyncio.sleep(delay)
    else:
        await asyncio.sleep(0)


async def _broadcast(message: dict[str, Any]) -> None:
    for peer in tuple(clients):
        peer.publish(message)


async def _watch_recording() -> None:
    previous = None
    while logger is not None:
        recording = logger.snapshot()
        if recording["state"] == "failed" and stream_state["error"] is None:
            _fail_stream("recording_failed")
        state = recording["state"]
        if state != previous:
            for peer in tuple(clients):
                try:
                    peer.control({"v": 1, "type": "recording_status", "recording": recording})
                except OverflowError:
                    peer.stop()
            previous = state
        await asyncio.sleep(0.1)


async def can_broadcast_loop() -> None:
    period = 1.0 / settings.can_hz
    next_tick = time.perf_counter()

    while True:
        if stream_state["error"]:
            return
        next_tick += period

        seq = stream_state["seq"]
        should_sim_drop = (
            settings.simulate_drop_every > 0
            and seq > 0
            and seq % settings.simulate_drop_every == 0
        )

        if should_sim_drop:
            stream_state["drop"] += 1

        try:
            raw_sig = can_source.next_frame()
            # Validate before clamping: max(0, NaN) can otherwise become a fake zero.
            if not isinstance(raw_sig, dict) or any(
                type(value) not in (int, float) or not math.isfinite(value)
                for value in raw_sig.values()
            ):
                raise ValueError("invalid_signal_snapshot")
            sig = signal_mapper.apply(raw_sig)
            if any(not math.isfinite(value) for value in sig.values()):
                raise ValueError("nonfinite_signal")
        except Exception:
            _fail_stream("source_failed")
            return

        frame = {
            "v": 1,
            "t": time.time(),
            "sig": sig,
            "status": {
                "seq": seq,
                "drop": stream_state["drop"],
            },
        }

        try:
            logger.log_can(frame)
        except Exception:
            _fail_stream("recording_failed")
            return
        frame["status"]["recording"] = logger.snapshot()
        stream_state["last_frame"] = time.perf_counter()
        if stream_ready:
            stream_ready.set()
        if not should_sim_drop:
            await _broadcast(frame)

        stream_state["seq"] += 1
        await _sleep_until(next_tick)


@asynccontextmanager
async def lifespan(application: FastAPI):
    global broadcast_task, recording_task, http_client, logger, stream_ready, can_source, signal_mapper

    if not CLIENT_DIR.exists():
        raise RuntimeError(f"client directory not found: {CLIENT_DIR}")

    cleanup = AsyncExitStack()
    async def stop_task(task):
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception:
            _fail_stream("stream_unavailable")

    async def stop_peers():
        peers = tuple(clients)
        for peer in peers:
            peer.stop()
        if peers:
            await asyncio.gather(*(peer.finished.wait() for peer in peers))

    async def close_recording(recorder):
        report = await recorder.close()
        application.state.recording_shutdown = report
        if report["unconfirmed"] or report["error"] or report["worker_alive"]:
            log.error("CSV shutdown not clean: error=%s unconfirmed=%d rejected=%d worker_alive=%s",
                      report["error"], report["unconfirmed"], report["rejected"], report["worker_alive"])

    try:
        can_source = create_can_source(settings.can_source)
        signal_mapper = SignalMapper(settings.signals_config)
        logger = AsyncCsvRecorder(settings.log_dir)
        cleanup.push_async_callback(close_recording, logger)
        await logger.start()
        stream_state.update(seq=0, drop=0, error=None, last_frame=None)
        stream_ready = asyncio.Event()
        application.state.ingest_token = settings.ingest_token
        application.state.ingest_journal = (
            await asyncio.to_thread(TelemetryJournal, settings.log_dir / "telemetry.sqlite3")
            if settings.ingest_token else None
        )
        http_client = httpx.AsyncClient(timeout=httpx.Timeout(4.0))
        cleanup.push_async_callback(http_client.aclose)
        cleanup.push_async_callback(stop_peers)
        broadcast_task = asyncio.create_task(can_broadcast_loop())
        recording_task = asyncio.create_task(_watch_recording())
        cleanup.push_async_callback(stop_task, recording_task)
        cleanup.push_async_callback(stop_task, broadcast_task)
        readiness = asyncio.create_task(stream_ready.wait())
        try:
            await asyncio.wait((readiness, broadcast_task), return_when=asyncio.FIRST_COMPLETED)
        finally:
            readiness.cancel()
            with suppress(asyncio.CancelledError):
                await readiness
        log.info("session=%s", logger.session_id)
        log.info("logs: %s", settings.log_dir)
        log.info("signals config: %s", settings.signals_config)
        log.info("static client: %s", CLIENT_DIR)
        yield
    finally:
        try:
            with anyio.CancelScope(shield=True):
                async def finish_cleanup():
                    with anyio.CancelScope(shield=True):
                        await cleanup.aclose()
                finishing = asyncio.create_task(finish_cleanup())
                cancelled = False
                while True:
                    try:
                        await asyncio.shield(finishing)
                        break
                    except asyncio.CancelledError:
                        if finishing.done():
                            raise
                        cancelled = True
                if cancelled:
                    raise asyncio.CancelledError()
        finally:
            logger = None
            http_client = None
            broadcast_task = None
            recording_task = None
            stream_ready = None
            application.state.ingest_journal = None
            application.state.ingest_token = None


app = FastAPI(title="Telemetry Dashboard", version="0.1.0", lifespan=lifespan)
if settings.allowed_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.allowed_origins),
        allow_credentials=True,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Content-Type", "Authorization"],
    )


@app.get("/api/ping")
async def api_ping() -> JSONResponse:
    last_frame = stream_state["last_frame"]
    age = time.perf_counter() - last_frame if last_frame is not None else None
    error = stream_state["error"]
    recording = logger.snapshot() if logger else None
    if not error and recording and recording["state"] != "ready":
        error = "recording_failed" if recording["state"] == "failed" else "recording_delayed"
    if not error and (not logger or not broadcast_task or broadcast_task.done()):
        error = "stream_unavailable"
    if not error and (age is None or age > max(1.0, 5.0 / settings.can_hz)):
        error = "stream_stale"
    payload = {
        "ok": error is None,
        "t": time.time(),
        "session": logger.session_id if logger else None,
        "stream": {"seq": stream_state["seq"], "drop": stream_state["drop"],
                   "last_frame_age_ms": round(age * 1000) if age is not None else None},
        "recording": recording,
    }
    if error:
        payload["error"] = {"code": error}
    return JSONResponse(payload, status_code=503 if error else 200,
                        headers={"Cache-Control": "no-store"})


@app.get("/api/public-config")
async def api_public_config() -> dict[str, Any]:
    return {
        "ok": True,
        "naver": {
            "clientId": settings.naver_maps_client_id,
            "enabled": bool(settings.naver_maps_client_id),
        },
    }


def _format_naver_address(payload: dict[str, Any]) -> str | None:
    results = payload.get("results")
    if not isinstance(results, list) or not results:
        return None

    for item in results:
        if not isinstance(item, dict):
            continue

        region = item.get("region") if isinstance(item.get("region"), dict) else {}
        land = item.get("land") if isinstance(item.get("land"), dict) else {}

        region_names: list[str] = []
        for area in ("area1", "area2", "area3", "area4"):
            node = region.get(area)
            if isinstance(node, dict):
                name = node.get("name")
                if name:
                    region_names.append(str(name))

        land_name = land.get("name")
        number1 = land.get("number1")
        number2 = land.get("number2")

        number = ""
        if number1:
            number = str(number1)
        if number2:
            number = f"{number}-{number2}" if number else str(number2)

        parts = region_names
        if land_name:
            parts.append(str(land_name))
        if number:
            parts.append(str(number))

        address = " ".join([p for p in parts if p]).strip()
        if address:
            return address

    return None


def _safe_json(response: httpx.Response) -> dict[str, Any] | None:
    try:
        payload = response.json()
    except ValueError:
        return None
    return payload if isinstance(payload, dict) else None


def _extract_naver_error(payload: dict[str, Any] | None) -> str | None:
    if not isinstance(payload, dict):
        return None

    status = payload.get("status")
    if isinstance(status, dict):
        code = status.get("code")
        if code not in (None, 0, "0"):
            name = status.get("name")
            message = status.get("message")
            parts = [p for p in [name, f"code={code}", message] if p]
            if parts:
                return ", ".join(str(p) for p in parts)
            return f"code={code}"

    error = payload.get("error")
    if isinstance(error, dict):
        code = error.get("errorCode") or error.get("code")
        message = error.get("message")
        if code or message:
            return f"{code or 'error'}: {message or ''}".strip()

    return None


def _short_error_detail(payload: dict[str, Any] | None, response: httpx.Response) -> str:
    from_payload = _extract_naver_error(payload)
    if from_payload:
        return from_payload

    text = response.text.strip().replace("\n", " ")
    if text:
        return text[:220]
    return "no detail"


@app.get("/api/naver/reverse-geocode")
async def api_naver_reverse_geocode(lat: float, lon: float) -> dict[str, Any]:
    if not settings.naver_maps_client_id or not settings.naver_maps_client_secret:
        raise HTTPException(status_code=503, detail="NAVER_MAPS_CLIENT_ID/SECRET not configured")

    if http_client is None:
        raise HTTPException(status_code=503, detail="HTTP client not initialized")

    if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
        raise HTTPException(status_code=422, detail="Invalid lat/lon range")

    params = {
        "request": "coordsToaddr",
        "coords": f"{lon},{lat}",
        "sourcecrs": "epsg:4326",
        "output": "json",
        "orders": "roadaddr,addr",
    }
    headers = {
        "X-NCP-APIGW-API-KEY-ID": settings.naver_maps_client_id,
        "X-NCP-APIGW-API-KEY": settings.naver_maps_client_secret,
    }

    hosts = [
        "https://maps.apigw.ntruss.com/map-reversegeocode/v2/gc",
        "https://naveropenapi.apigw.ntruss.com/map-reversegeocode/v2/gc",
    ]

    last_error: str | None = None
    auth_error: HTTPException | None = None
    rate_limit_error: HTTPException | None = None
    for url in hosts:
        try:
            response = await http_client.get(url, params=params, headers=headers)
            payload = _safe_json(response)
            status_code = response.status_code

            if status_code in (401, 403):
                detail = _short_error_detail(payload, response)
                auth_error = HTTPException(
                    status_code=status_code,
                    detail=f"Naver reverse-geocode auth failed ({url}): {detail}",
                )
                last_error = f"{url} -> HTTP {status_code} ({detail})"
                continue

            if status_code == 429:
                detail = _short_error_detail(payload, response)
                rate_limit_error = HTTPException(
                    status_code=429,
                    detail=f"Naver reverse-geocode rate limited ({url}): {detail}",
                )
                last_error = f"{url} -> HTTP 429 ({detail})"
                continue

            if status_code != 200:
                detail = _short_error_detail(payload, response)
                last_error = f"{url} -> HTTP {status_code} ({detail})"
                log.warning("reverse-geocode fallback: %s", last_error)
                continue

            if not payload:
                last_error = f"{url} -> invalid JSON payload"
                log.warning("reverse-geocode invalid payload: %s", last_error)
                continue

            api_error = _extract_naver_error(payload)
            if api_error:
                last_error = f"{url} -> API error ({api_error})"
                log.warning("reverse-geocode API error: %s", last_error)
                continue

            address = _format_naver_address(payload)
            return {
                "ok": True,
                "address": address,
                "raw": payload if address is None else None,
            }
        except Exception as exc:
            last_error = str(exc)
            log.warning("reverse-geocode exception (%s): %s", url, exc)

    if auth_error:
        raise auth_error
    if rate_limit_error:
        raise rate_limit_error

    raise HTTPException(status_code=502, detail=f"Naver reverse-geocode failed: {last_error}")


async def _record_uplink(kind: str, row: dict[str, Any]) -> None:
    if logger is None:
        raise UplinkError("storage_unavailable")
    try:
        if kind == "GPS":
            ticket = logger.log_gps(row)
        else:
            ticket = logger.log_event(row)
        await logger.confirm(ticket)
    except (OSError, ValueError):
        raise UplinkError("storage_unavailable") from None


async def _legacy_http(request: Request, expected: str) -> JSONResponse:
    try:
        if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
            raise UplinkError("unsupported_media_type")
        body = bytearray()
        async for chunk in request.stream():
            if len(body) + len(chunk) > MAX_UPLINK_BYTES:
                raise UplinkError("payload_too_large")
            body.extend(chunk)
        kind, row = decode_uplink(body)
        if kind != expected:
            raise UplinkError("invalid_payload")
        await _record_uplink(kind, row)
    except UplinkError as error:
        return JSONResponse(error.payload(), status_code=error.status,
                            headers={"Cache-Control": "no-store"})
    return JSONResponse({"ok": True}, headers={"Cache-Control": "no-store"})


@app.post("/api/gps")
async def api_gps(request: Request) -> JSONResponse:
    return await _legacy_http(request, "GPS")


@app.post("/api/event")
async def api_event(request: Request) -> JSONResponse:
    return await _legacy_http(request, "MARK")


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    peer = StreamPeer(ws)
    clients.add(peer)
    if logger and logger.snapshot()["state"] != "ready":
        peer.control({"v": 1, "type": "recording_status", "recording": logger.snapshot()})

    async def receive() -> None:
        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                return
            try:
                raw = message.get("text")
                if raw is None:
                    raise UplinkError("text_frame_required")
                kind, row = decode_uplink(raw)
                if kind == "ping":
                    peer.control({"v": 1, "type": "pong", "t": row["t"], "server_t": time.time()})
                else:
                    await _record_uplink(kind, row)
            except UplinkError as error:
                peer.control({"v": 1, "type": "error", **error.payload()})

    try:
        await peer.run(receive)
    except (WebSocketDisconnect, TimeoutError, OSError, OverflowError):
        pass
    finally:
        clients.discard(peer)


app.include_router(reliable_router)
app.mount("/", StaticFiles(directory=str(CLIENT_DIR), html=True), name="client")


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        reload=False,
        ssl_certfile=settings.ssl_certfile,
        ssl_keyfile=settings.ssl_keyfile,
        ws_max_size=MAX_UPLINK_BYTES,
        ws_max_queue=8,
    )
