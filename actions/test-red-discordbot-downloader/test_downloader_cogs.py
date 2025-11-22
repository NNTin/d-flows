#!/usr/bin/env python3
"""Install and validate Red-DiscordBot cogs through the downloader cog."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path
from typing import Iterable, List, Sequence

import aiohttp
import shutil

from redbot.cogs.downloader import errors as downloader_errors
from redbot.cogs.downloader.repo_manager import Repo, RepoManager
from redbot.core import data_manager
from redbot.core._cog_manager import CogManager

JSONRPC_VERSION = "2.0"
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
                raise RPCProtocolError(
                    f"Invalid JSON payload from RPC server: {message.data}"
                ) from exc
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


def parse_env() -> tuple[List[Path], int, str, Path | None, str, str | None]:
    raw_paths = os.environ.get("COG_PATHS", "")
    port_raw = os.environ.get("RPC_PORT", "6133")
    try:
        port = int(port_raw)
    except ValueError as exc:
        raise RuntimeError(f"RPC_PORT must be an integer (received {port_raw!r})") from exc

    repo_name_raw = os.environ.get("REPO_NAME", "test-repo").strip()
    repo_path_raw = os.environ.get("REPO_PATH", "").strip()
    repo_url_raw = os.environ.get("REPO_URL", "").strip()
    repo_path: Path | None = None
    if repo_url_raw:
        if repo_path_raw:
            repo_path = Path(repo_path_raw).resolve()
    else:
        if not repo_path_raw:
            raise RuntimeError("REPO_PATH environment variable must be provided")
        repo_path = Path(repo_path_raw).resolve()
    repo_branch_raw = os.environ.get("REPO_BRANCH", "").strip()
    repo_branch = repo_branch_raw or None

    cog_paths: List[Path] = []
    if raw_paths:
        for chunk in raw_paths.split(","):
            candidate = chunk.strip()
            if not candidate:
                continue
            candidate_path = Path(candidate).expanduser()
            if not candidate_path.exists():
                raise RuntimeError(f"Cog path does not exist: {candidate}")
            cog_paths.append(candidate_path.resolve())

    if not repo_url_raw and not cog_paths:
        raise RuntimeError("COG_PATHS must list at least one directory when REPO_URL is empty")

    return cog_paths, port, repo_name_raw, repo_path, repo_url_raw, repo_branch


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


def normalize_repo_name(name: str) -> str:
    sanitized = name.strip().replace("-", "_")
    try:
        return RepoManager.validate_and_normalize_repo_name(sanitized)
    except downloader_errors.InvalidRepoName as exc:
        raise RuntimeError(f"Invalid downloader repo name: {name}") from exc


async def setup_repo_manager() -> RepoManager:
    data_manager.load_basic_configuration("tinkerer")
    manager = RepoManager()
    await manager.initialize()
    return manager


async def add_test_repo(
    manager: RepoManager, name: str, url: str, branch: str | None
) -> Repo:
    normalized = normalize_repo_name(name)
    if manager.does_repo_exist(normalized):
        print(f"♻️ Removing pre-existing repo {normalized}")
        await manager.delete_repo(normalized)
    print(f"➕ Adding downloader repo {normalized} from {url}")
    try:
        repo = await manager.add_repo(url=url, name=normalized, branch=branch)
    except downloader_errors.DownloaderException as exc:
        raise RuntimeError(f"Failed to add downloader repo {normalized}: {exc}") from exc
    return repo


async def get_cog_install_path() -> Path:
    manager = CogManager()
    path = await manager.install_path()
    path.mkdir(parents=True, exist_ok=True)
    return path


def ensure_lib_paths() -> Path:
    base = data_manager.cog_data_path(raw_name="Downloader") / "lib"
    shared = base / "cog_shared"
    shared.mkdir(parents=True, exist_ok=True)
    init_path = shared / "__init__.py"
    if not init_path.exists():
        init_path.write_text("", encoding="utf-8")
    return base


async def install_cogs_from_repo(
    repo: Repo,
    install_path: Path,
    requirements_path: Path,
    expected_names: Sequence[str],
) -> List[str]:
    available = {cog.name: cog for cog in repo.available_cogs}
    missing = [name for name in expected_names if name not in available]
    if missing:
        raise RuntimeError(f"Repository did not contain expected cogs: {', '.join(missing)}")

    installed: List[str] = []
    for name in expected_names:
        cog = available[name]
        print(f"🧩 Installing cog {name} via downloader")
        target = install_path / name
        if target.exists():
            print(f"♻️ Removing existing cog directory at {target}")
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
        try:
            await repo.install_cog(cog, target_dir=install_path)
        except downloader_errors.DownloaderException as exc:
            raise RuntimeError(f"Failed to install cog {name} from {repo.name}: {exc}") from exc
        if cog.requirements:
            ok = await repo.install_requirements(cog=cog, target_dir=requirements_path)
            if not ok:
                raise RuntimeError(f"Failed to install requirements for {name}")
        installed.append(name)
    return installed


async def exercise_cogs(client: JsonRpcClient, names: Iterable[str]) -> None:
    for name in names:
        await load_cog(client, name)
        await unload_cog(client, name)


def cleanup_installed_cogs(install_path: Path, names: Iterable[str]) -> None:
    for name in names:
        target = install_path / name
        if target.exists():
            print(f"🧽 Removing installed cog {name} from {target}")
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()


async def main_async() -> None:
    cog_paths, port, repo_name, repo_path, repo_url, repo_branch = parse_env()
    if repo_url:
        repo_target = repo_url
    elif repo_path is not None:
        repo_target = str(repo_path)
    else:  # pragma: no cover - defensive guard
        raise RuntimeError("Neither repo_url nor repo_path was provided")
    if cog_paths:
        expected_names: List[str] | None = [cog_name_from_path(path) for path in cog_paths]
    else:
        expected_names = None

    repo_manager = await setup_repo_manager()
    install_path = await get_cog_install_path()
    requirements_path = ensure_lib_paths()

    repo: Repo | None = None
    installed: List[str] = []
    try:
        repo = await add_test_repo(repo_manager, repo_name, repo_target, repo_branch)
        if expected_names is None:
            expected_names = sorted(cog.name for cog in repo.available_cogs)
            if not expected_names:
                raise RuntimeError(f"Repository {repo.name} does not contain any cogs to test")
            print(
                f"🧭 No COG_PATHS specified; exercising all {len(expected_names)} cogs from {repo.name}"
            )
        assert expected_names is not None
        installed = await install_cogs_from_repo(
            repo, install_path, requirements_path, expected_names
        )

        rpc_url = RPC_URL_TEMPLATE.format(port=port)
        print(f"🔌 Validating {len(installed)} cog(s) at {rpc_url}")
        async with aiohttp.ClientSession() as session:
            await wait_for_rpc(session, rpc_url)
            async with JsonRpcClient(session, rpc_url) as client:
                await exercise_cogs(client, installed)

        print("🎯 Downloader installation tests passed")
    finally:
        cleanup_installed_cogs(install_path, installed)
        if repo is not None:
            try:
                await repo_manager.delete_repo(repo.name)
            except downloader_errors.DownloaderException as exc:
                repo_path = repo_manager.repos_folder / repo.name
                print(f"⚠️ Failed to remove downloader repo {repo.name} at {repo_path}: {exc}")
                try:
                    if repo_path.exists():
                        shutil.rmtree(repo_path)
                        print(f"🧽 Removed repo directory {repo_path} via fallback cleanup")
                except Exception as cleanup_exc:  # pragma: no cover - best effort cleanup
                    print(f"⚠️ Failed to remove repo directory {repo_path}: {cleanup_exc}")


def main() -> None:
    try:
        asyncio.run(main_async())
    except Exception as exc:
        print(f"❌ {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
