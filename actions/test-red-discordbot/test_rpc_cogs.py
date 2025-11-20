#!/usr/bin/env python3
"""Exercise Red-DiscordBot RPC load/unload handlers for configured cogs."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from typing import List

import aiohttp

JSONRPC_VERSION = "2.0"
# RPC server defined in redbot/core/_rpc.py binds websocket listener to "/"
RPC_URL_TEMPLATE = "ws://127.0.0.1:{port}/"
CORE_LOAD_METHOD = "CORE__LOAD"
CORE_UNLOAD_METHOD = "CORE__UNLOAD"
RPC_WAIT_TIMEOUT = 30
RPC_WAIT_INTERVAL = 0.5

try:
    from aiohttp import ClientWSTimeout
except ImportError:  # pragma: no cover - fallback for older aiohttp
    ClientWSTimeout = None  # type: ignore[assignment]


def _ws_timeout(seconds: float):
    if ClientWSTimeout is None:
        return seconds
    return ClientWSTimeout(ws_close=seconds)


WS_CONNECT_TIMEOUT = _ws_timeout(10)
WS_WAIT_TIMEOUT = _ws_timeout(3)


class RPCError(RuntimeError):
    """Raised when the RPC server reports an error."""


class RPCProtocolError(RuntimeError):
    """Raised when the RPC response payload is malformed."""


class JsonRpcClient:
    """Simple JSON-RPC client that reuses a single websocket connection."""

    def __init__(self, session: aiohttp.ClientSession, url: str) -> None:
        self._session = session
        self._url = url
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._next_id = 1

    async def __aenter__(self) -> "JsonRpcClient":
        self._ws = await self._session.ws_connect(self._url, timeout=WS_CONNECT_TIMEOUT)
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        if self._ws is not None:
            await self._ws.close()
            self._ws = None

    async def request(self, method: str, params: list | None = None, *, timeout: int = 30):
        if self._ws is None:
            raise RPCProtocolError("WebSocket connection has not been established yet")

        request_id = self._next_id
        self._next_id += 1
        payload = {"jsonrpc": JSONRPC_VERSION, "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params

        await self._ws.send_json(payload)
        try:
            message = await asyncio.wait_for(self._ws.receive(), timeout=timeout)
        except asyncio.TimeoutError as exc:  # pragma: no cover - runtime guard
            raise RPCError(f"Timed out waiting for RPC response to {method}") from exc

        if message.type == aiohttp.WSMsgType.TEXT:
            try:
                response = json.loads(message.data)
            except json.JSONDecodeError as exc:  # pragma: no cover - runtime guard
                raise RPCProtocolError(f"Invalid JSON payload from RPC server: {message.data}") from exc
        elif message.type == aiohttp.WSMsgType.ERROR:
            raise RPCError(f"WebSocket error while calling {method}: {self._ws.exception()}")
        else:  # pragma: no cover - runtime guard
            raise RPCProtocolError(f"Unexpected WebSocket message type: {message.type}")

        if response.get("id") != request_id:
            raise RPCProtocolError(
                f"Mismatched RPC response id. Expected {request_id}, got {response.get('id')}"
            )

        if "error" in response:
            raise RPCError(f"RPC call {method} failed: {response['error']}")
        return response.get("result")


def parse_env() -> tuple[List[Path], int]:
    raw_paths = os.environ.get("COG_PATHS")
    if not raw_paths:
        raise RuntimeError("COG_PATHS environment variable must be provided")

    port_raw = os.environ.get("RPC_PORT", "6133")
    try:
        port = int(port_raw)
    except ValueError as exc:
        raise RuntimeError(f"RPC_PORT must be an integer (received {port_raw!r})") from exc

    cog_paths: List[Path] = []
    for chunk in raw_paths.split(","):
        candidate = chunk.strip()
        if not candidate:
            continue
        candidate_path = Path(candidate).expanduser()
        if not candidate_path.exists():
            raise RuntimeError(f"Cog path does not exist: {candidate}")
        cog_paths.append(candidate_path.resolve())

    if not cog_paths:
        raise RuntimeError("COG_PATHS did not contain any usable paths")

    return cog_paths, port


async def wait_for_rpc(session: aiohttp.ClientSession, url: str) -> None:
    """Poll the RPC endpoint until a websocket handshake succeeds or timeout occurs."""

    start = time.monotonic()
    while True:
        try:
            async with session.ws_connect(url, timeout=WS_WAIT_TIMEOUT):
                print(f"🟢 RPC endpoint {url} is ready")
                return
        except (aiohttp.ClientError, OSError):
            if time.monotonic() - start >= RPC_WAIT_TIMEOUT:
                raise RuntimeError(f"Timed out waiting for RPC endpoint at {url}")
            await asyncio.sleep(RPC_WAIT_INTERVAL)


def cog_name_from_path(path: Path) -> str:
    cog_name = path.name
    if not cog_name:
        raise RuntimeError(f"Could not derive cog name from {path}")
    return cog_name


async def load_cog(client: JsonRpcClient, cog_name: str) -> None:
    print(f"📥 Loading cog {cog_name}")
    result = await client.request(CORE_LOAD_METHOD, [[cog_name]])
    loaded = (result or {}).get("loaded_packages", [])
    failed = (result or {}).get("failed_packages", [])
    if cog_name not in loaded:
        raise RPCError(f"RPC did not report {cog_name} in loaded_packages: {result}")
    if failed:
        raise RPCError(f"RPC reported failed packages while loading {cog_name}: {failed}")
    print(f"✅ Cog {cog_name} loaded successfully")


async def unload_cog(client: JsonRpcClient, cog_name: str) -> None:
    print(f"📤 Unloading cog {cog_name}")
    result = await client.request(CORE_UNLOAD_METHOD, [[cog_name]])
    unloaded = (result or {}).get("unloaded_packages", [])
    if cog_name not in unloaded:
        raise RPCError(f"RPC did not report {cog_name} in unloaded_packages: {result}")
    print(f"♻️ Cog {cog_name} unloaded successfully")


async def exercise_cog(client: JsonRpcClient, path: Path) -> None:
    cog_name = cog_name_from_path(path)
    await load_cog(client, cog_name)
    await unload_cog(client, cog_name)


async def main_async() -> None:
    cog_paths, port = parse_env()
    rpc_url = RPC_URL_TEMPLATE.format(port=port)
    print(f"🔌 Validating {len(cog_paths)} cog(s) against RPC at {rpc_url}")
    async with aiohttp.ClientSession() as session:
        await wait_for_rpc(session, rpc_url)
        async with JsonRpcClient(session, rpc_url) as client:
            for path in cog_paths:
                await exercise_cog(client, path)

    print("🎯 All cog RPC tests passed")


def main() -> None:
    try:
        asyncio.run(main_async())
    except Exception as exc:
        print(f"❌ {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
