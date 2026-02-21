from __future__ import annotations

import asyncio
import json
import logging
import time
from contextlib import suppress
from typing import Any

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from can_source import create_can_source
from config import CLIENT_DIR, settings
from gps_sink import extract_event_row, extract_gps_row
from logger import SessionCsvLogger

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
log = logging.getLogger("telemetry-server")

app = FastAPI(title="Telemetry Dashboard", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

can_source = create_can_source(settings.can_source)
logger = SessionCsvLogger(settings.log_dir)

clients: set[WebSocket] = set()
clients_lock = asyncio.Lock()

broadcast_task: asyncio.Task[None] | None = None
http_client: httpx.AsyncClient | None = None
stream_state = {"seq": 0, "drop": 0}


async def _sleep_until(target: float) -> None:
    delay = target - time.perf_counter()
    if delay > 0:
        await asyncio.sleep(delay)
    else:
        await asyncio.sleep(0)


async def _broadcast(message: dict[str, Any]) -> None:
    async with clients_lock:
        sockets = list(clients)

    if not sockets:
        return

    dead: list[WebSocket] = []
    for ws in sockets:
        try:
            await ws.send_json(message)
        except Exception:
            dead.append(ws)

    if dead:
        async with clients_lock:
            for ws in dead:
                clients.discard(ws)


async def can_broadcast_loop() -> None:
    period = 1.0 / settings.can_hz
    next_tick = time.perf_counter()

    while True:
        next_tick += period

        seq = stream_state["seq"]
        should_sim_drop = (
            settings.simulate_drop_every > 0
            and seq > 0
            and seq % settings.simulate_drop_every == 0
        )

        if should_sim_drop:
            stream_state["drop"] += 1
            stream_state["seq"] += 1
            await _sleep_until(next_tick)
            continue

        frame = {
            "v": 1,
            "t": time.time(),
            "sig": can_source.next_frame(),
            "status": {
                "seq": seq,
                "drop": stream_state["drop"],
            },
        }

        logger.log_can(frame)
        await _broadcast(frame)

        stream_state["seq"] += 1
        await _sleep_until(next_tick)


@app.on_event("startup")
async def on_startup() -> None:
    global broadcast_task, http_client

    if not CLIENT_DIR.exists():
        raise RuntimeError(f"client directory not found: {CLIENT_DIR}")

    broadcast_task = asyncio.create_task(can_broadcast_loop())
    http_client = httpx.AsyncClient(timeout=httpx.Timeout(4.0))
    log.info("session=%s", logger.session_id)
    log.info("logs: %s", settings.log_dir)
    log.info("static client: %s", CLIENT_DIR)


@app.on_event("shutdown")
async def on_shutdown() -> None:
    global http_client

    if broadcast_task:
        broadcast_task.cancel()
        with suppress(asyncio.CancelledError):
            await broadcast_task

    if http_client:
        await http_client.aclose()
        http_client = None

    logger.close()


@app.get("/api/ping")
async def api_ping() -> dict[str, Any]:
    return {"ok": True, "t": time.time(), "session": logger.session_id}


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


@app.get("/api/naver/reverse-geocode")
async def api_naver_reverse_geocode(lat: float, lon: float) -> dict[str, Any]:
    if not settings.naver_maps_client_id or not settings.naver_maps_client_secret:
        raise HTTPException(status_code=503, detail="NAVER_MAPS_CLIENT_ID/SECRET not configured")

    if http_client is None:
        raise HTTPException(status_code=503, detail="HTTP client not initialized")

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
    for url in hosts:
        try:
            response = await http_client.get(url, params=params, headers=headers)
            if response.status_code != 200:
                last_error = f"{url} -> {response.status_code}"
                continue

            payload = response.json()
            address = _format_naver_address(payload)
            return {
                "ok": True,
                "address": address,
                "raw": payload if address is None else None,
            }
        except Exception as exc:
            last_error = str(exc)

    raise HTTPException(status_code=502, detail=f"Naver reverse-geocode failed: {last_error}")


@app.post("/api/gps")
async def api_gps(payload: dict[str, Any]) -> dict[str, bool]:
    row = extract_gps_row(payload)
    if not row:
        raise HTTPException(status_code=400, detail="Invalid GPS payload")
    logger.log_gps(row)
    return {"ok": True}


@app.post("/api/event")
async def api_event(payload: dict[str, Any]) -> dict[str, bool]:
    row = extract_event_row(payload)
    if not row:
        raise HTTPException(status_code=400, detail="Invalid event payload")
    logger.log_event(row)
    return {"ok": True}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    await ws.accept()

    async with clients_lock:
        clients.add(ws)

    try:
        while True:
            raw = await ws.receive_text()

            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                continue

            msg_type = payload.get("type")

            if msg_type == "ping":
                await ws.send_json(
                    {
                        "v": 1,
                        "type": "pong",
                        "t": payload.get("t"),
                        "server_t": time.time(),
                    }
                )
                continue

            gps_row = extract_gps_row(payload)
            if gps_row:
                logger.log_gps(gps_row)
                continue

            event_row = extract_event_row(payload)
            if event_row:
                logger.log_event(event_row)

    except WebSocketDisconnect:
        pass
    finally:
        async with clients_lock:
            clients.discard(ws)


app.mount("/", StaticFiles(directory=str(CLIENT_DIR), html=True), name="client")


if __name__ == "__main__":
    uvicorn.run(
        "app:app",
        host=settings.host,
        port=settings.port,
        reload=False,
        ssl_certfile=settings.ssl_certfile,
        ssl_keyfile=settings.ssl_keyfile,
    )
