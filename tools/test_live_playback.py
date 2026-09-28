#!/usr/bin/env python3
"""Opt-in, bounded Spotify playback check. Close Tops before running.

    python3 tools/test_live_playback.py --playback

Uses Tops' original session directory so refreshed grants stay in the right place.
Never prints account details, credentials, raw responses, or track metadata. This
starts real playback at low volume and pauses before shutting down its own engine.
"""
import argparse
import asyncio
import json
import platform
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = "https://api-partner.spotify.com/pathfinder/v2/query"


class CheckFailed(Exception):
    """Only fixed, credential-free messages belong here."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def report(phase, **numbers):
    print(json.dumps({"phase": phase, **numbers}), flush=True)


class Engine:
    def __init__(self, process):
        self.process = process
        self.next_id = 0
        self.sequence = 0
        self.playback = {}
        self.frames = []
        self.closing = False

    async def read(self, timeout):
        try:
            line = await asyncio.wait_for(self.process.stdout.readline(), timeout)
        except asyncio.TimeoutError:
            raise CheckFailed("Engine response timed out") from None
        if not line:
            raise CheckFailed("Engine stopped before completing the check")
        try:
            frame = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            raise CheckFailed("Engine returned an invalid protocol frame") from None
        if not isinstance(frame, dict):
            raise CheckFailed("Engine returned an invalid protocol frame")
        event, data = frame.get("event"), frame.get("data", {})
        if event == "playback" and isinstance(data, dict):
            self.sequence += 1
            self.playback = data
            self.frames.append((self.sequence, data))
            self.frames = self.frames[-256:]
        if not self.closing:
            if event == "error":
                raise CheckFailed("Playback engine reported a track error")
            if event == "connection" and data.get("connected") is False:
                raise CheckFailed("Spotify connection ended during the check")
            if event == "authentication" and data.get("state") == "waiting_for_browser":
                raise CheckFailed("Saved session needs interactive sign-in; reconnect Tops first")
        return frame

    async def call(self, method, params=None, timeout=8):
        self.next_id += 1
        request_id = self.next_id
        self.process.stdin.write((json.dumps({
            "id": request_id, "method": method, "params": params or {}
        }) + "\n").encode())
        await self.process.stdin.drain()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = await self.read(max(0.01, deadline - time.monotonic()))
            if frame.get("id") == request_id:
                if "error" in frame:
                    # Do not pass through upstream strings, even on authentication errors.
                    raise CheckFailed("Engine command failed: " + method)
                result = frame.get("result")
                if not isinstance(result, dict):
                    raise CheckFailed("Engine returned an invalid command result")
                return result
        raise CheckFailed("Engine command timed out: " + method)

    async def until(self, predicate, timeout, failure):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() >= deadline:
                raise CheckFailed(failure)
            try:
                await self.read(max(0.01, deadline - time.monotonic()))
            except CheckFailed as error:
                if str(error) == "Engine response timed out":
                    raise CheckFailed(failure) from None
                raise

    async def close(self):
        # Always try pause, even if the playback test failed partway through.
        self.closing = True
        pause_confirmed = False
        if self.process.returncode is None:
            try:
                await self.call("pause", timeout=3)
                await self.until(lambda: self.playback.get("is_playing") is False,
                                 3, "Pause cleanup timed out")
                pause_confirmed = True
            except Exception:
                pass
            try:
                await self.call("shutdown", timeout=3)
            except Exception:
                pass
            self.process.stdin.close()
            try:
                await asyncio.wait_for(self.process.wait(), 3)
            except asyncio.TimeoutError:
                self.process.terminate()
                try:
                    await asyncio.wait_for(self.process.wait(), 2)
                except asyncio.TimeoutError:
                    self.process.kill()
                    await asyncio.wait_for(self.process.wait(), 2)
        report("cleanup", pause_confirmed=pause_confirmed,
               owned_engine_stopped=self.process.returncode is not None)


def search_request(auth, operation_hash):
    access, client = auth.get("access_token"), auth.get("client_token")
    if not isinstance(access, str) or not isinstance(client, str) or not access or not client:
        raise CheckFailed("Engine did not return complete partner authorization")
    payload = {
        "operationName": "searchDesktop",
        "variables": {
            "searchTerm": "Daft Punk Get Lucky", "offset": 0, "limit": 20,
            "numberOfTopResults": 5, "includeAudiobooks": False,
            "includeArtistHasConcertsField": False, "includePreReleases": False,
            "includeLocalConcertsField": False, "includeAuthors": False,
            "includeAlbumPreReleases": False, "includeEpisodeContentRatingsV2": False,
            "isPrefix": None, "sectionFilters": ["GENERIC"],
        },
        "extensions": {"persistedQuery": {"version": 1, "sha256Hash": operation_hash}},
    }
    return Request(ENDPOINT, data=json.dumps(payload).encode(), method="POST", headers={
        "Authorization": "Bearer " + access, "client-token": client,
        "App-Platform": "OSX_ARM64" if platform.machine() == "arm64" else "OSX",
        "Origin": "https://xpui.app.spotify.com", "Referer": "https://xpui.app.spotify.com",
        "User-Agent": "Spotify/1.2.52.442 OSX/0 (Tops/0.1)",
        "Content-Type": "application/json", "Accept": "application/json", "Accept-Language": "en",
    })


def fetch_search(request):
    try:
        response = build_opener(NoRedirect).open(request, timeout=20)
    except HTTPError as error:
        # Do not consume or print error bodies or follow authenticated redirects.
        status = error.code
        error.close()
        return status, None
    with response:
        body = response.read(4_000_001)
        if len(body) > 4_000_000:
            raise CheckFailed("Search response exceeded its size limit")
        try:
            return response.status, json.loads(body)
        except (ValueError, UnicodeDecodeError):
            raise CheckFailed("Search returned invalid JSON") from None


def first_playable_track(root):
    if not isinstance(root, dict) or root.get("errors"):
        raise CheckFailed("Spotify search returned an API error")
    data = root.get("data") or {}
    search = data.get("searchV2") or data.get("search") or {}
    for key in ("tracksV2", "tracks"):
        for raw in (search.get(key) or {}).get("items", []):
            item = raw
            for _ in range(4):
                if not isinstance(item, dict) or "uri" in item:
                    break
                item = next((item[k] for k in ("item", "content", "data")
                             if isinstance(item.get(k), dict)), {})
            if not isinstance(item, dict):
                continue
            uri = item.get("uri", "")
            if (isinstance(uri, str) and re.fullmatch(r"spotify:track:[A-Za-z0-9]{22}", uri)
                    and (item.get("playability") or {}).get("playable") is True):
                return uri
    raise CheckFailed("Search returned no explicitly playable track")


async def validate(engine, operation_hash):
    await engine.call("authenticate", timeout=45)
    report("authenticated")
    for attempt in range(2):
        auth = await engine.call("partnerAuthContext", {"force_refresh": attempt == 1}, timeout=25)
        status, response = await asyncio.to_thread(fetch_search, search_request(auth, operation_hash))
        del auth
        if status == 401 and attempt == 0:
            continue
        if status != 200:
            raise CheckFailed("Search failed with HTTP " + str(status))
        uri = first_playable_track(response)
        del response
        break
    else:
        raise CheckFailed("Search authorization retry failed")
    report("search_playable_track_found")
    start = engine.sequence
    await engine.call("play", {"uri": uri})
    # Before play the inactive Connect device ignores volume commands.
    await engine.call("volume", {"percent": 10})

    def advancing():
        positions = [frame.get("position_ms", 0) for seq, frame in engine.frames
                     if seq > start and frame.get("track_uri") == uri
                     and frame.get("is_playing") is True and frame.get("title")
                     and frame.get("artist") and frame.get("duration_ms", 0) > 0]
        return sum(b - a > 500 for a, b in zip(positions, positions[1:])) >= 2

    await engine.until(advancing, 25, "Track did not produce metadata and advancing decoded positions")
    report("playing_metadata_and_progress_verified")
    paused_after = engine.sequence
    await engine.call("pause")
    await engine.until(lambda: any(seq > paused_after and f.get("track_uri") == uri
                                  and f.get("is_playing") is False for seq, f in engine.frames),
                       5, "Pause was not confirmed")
    before = await engine.call("status")
    await asyncio.sleep(2)
    after = await engine.call("status")
    if (before.get("is_playing") is not False or after.get("is_playing") is not False
            or abs(after.get("position_ms", 0) - before.get("position_ms", 0)) > 100):
        raise CheckFailed("Position continued advancing while paused")
    report("pause_hold_verified", hold_seconds=2)
    target = min(15000, int(after.get("duration_ms", 0)) // 4)
    if target <= 0:
        raise CheckFailed("Track duration was unavailable for seeking")
    seek_after = engine.sequence
    await engine.call("seek", {"position_ms": target})
    await engine.until(lambda: any(seq > seek_after and f.get("track_uri") == uri
                                  and f.get("is_playing") is False
                                  and abs(f.get("position_ms", -10000) - target) <= 1500
                                  for seq, f in engine.frames),
                       5, "Paused seek was not confirmed")
    report("paused_seek_verified", target_ms=target)
    resume_after = engine.sequence
    await engine.call("resume")
    await engine.until(lambda: any(seq > resume_after and f.get("track_uri") == uri
                                  and f.get("is_playing") is True
                                  and f.get("position_ms", 0) >= target + 1000
                                  for seq, f in engine.frames),
                       8, "Resume did not advance playback")
    report("resume_verified")


async def run(args, operation_hash):
    process = await asyncio.create_subprocess_exec(
        str(args.engine), "--data-dir", str(args.session_dir.resolve()),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, limit=2_000_000,
    )
    engine = Engine(process)
    task = asyncio.current_task()
    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGTERM, task.cancel)
    try:
        await asyncio.wait_for(validate(engine, operation_hash), timeout=150)
    finally:
        # Cancellation, timeouts and normal failures all terminate this owned process.
        await engine.close()
        loop.remove_signal_handler(signal.SIGTERM)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--playback", action="store_true", help="Explicitly permit real playback")
    parser.add_argument("--session-dir", type=Path,
                        default=Path.home() / "Library/Application Support/Tops/session")
    parser.add_argument("--engine", type=Path, default=ROOT / "engine/target/release/tops-engine")
    args = parser.parse_args()
    if not args.playback:
        parser.error("Pass --playback to explicitly permit real playback; close Tops first")
    try:
        existing = subprocess.run(["pgrep", "-x", "tops-engine"], capture_output=True, timeout=3)
        if existing.returncode == 0:
            raise CheckFailed("Another Tops engine is running; close Tops before testing")
        if existing.returncode != 1:
            raise CheckFailed("Could not establish exclusive engine ownership")
        if not (args.session_dir / "oauth.json").is_file():
            raise CheckFailed("No saved Tops session; sign in with the app first")
        manifest = json.loads((ROOT / "config/operations.json").read_text())
        operation_hash = manifest["operations"]["searchDesktop"]["hash"]
        if not isinstance(operation_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", operation_hash):
            raise CheckFailed("Search operation hash is invalid")
        asyncio.run(run(args, operation_hash))
    except CheckFailed as error:
        report("failed", reason=str(error))
        return 1
    except (KeyboardInterrupt, asyncio.CancelledError):
        report("interrupted")
        return 130
    except asyncio.TimeoutError:
        report("failed", reason="Live playback check exceeded its total time limit")
        return 1
    except Exception:
        # Suppress arbitrary exception strings and tracebacks: they can contain requests.
        report("failed", reason="Unexpected test failure; no raw diagnostics emitted")
        return 1
    report("passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
