#!/usr/bin/env python3
"""Extract Spotify's read-only persisted operations from public player assets.

No sign-in, cookies, browser profile, JavaScript execution, or third-party hash
service is used. The manifest records the exact public assets and their digests.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen


HOME_URL = "https://open.spotify.com/"
ENDPOINT = "https://api-partner.spotify.com/pathfinder/v2/query"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36"
)
CHUNK_NAMES = {"browse-v2", "home-v2-section", "xpui-routes-search"}
REQUIRED_OPERATIONS = {"home", "homeSection", "browsePage", "browseSection", "searchDesktop", "fetchPlaylist", "getAlbum", "queryArtistOverview"}
WANTED_OPERATIONS = REQUIRED_OPERATIONS | {
    "searchTracks", "searchAlbums", "searchArtists", "searchPlaylists",
    "fetchPlaylist", "fetchPlaylistContents", "fetchPlaylistMetadata", "getTrack",
    "getAlbum", "queryAlbumTracks", "queryArtistOverview",
}
MAX_ASSET_BYTES = 32 * 1024 * 1024
DESCRIPTOR_RE = re.compile(
    r'''["']([_A-Za-z][_A-Za-z0-9]*)["']\s*,\s*["'](query|mutation|subscription)["']'''
    r'''\s*,\s*["']([0-9a-fA-F]{64})["']\s*,\s*null\s*\)'''
)
# Only literal integer-to-safe-string tables are recognized. This is not a JS
# interpreter. CSS tables are explicitly excluded by the following .js suffix.
TABLE_RE = re.compile(
    r'\{\s*(?:(?:"[0-9]+"|[0-9]+)\s*:\s*"[A-Za-z0-9_.~-]+"\s*,?\s*)+\}'
)
JS_SUFFIX_RE = re.compile(r'\s*\)\s*\[\w+\]\s*\+\s*["\']\.js["\']')


class ScriptSources(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.urls: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "script":
            source = dict(attrs).get("src")
            if source:
                self.urls.append(source)


def public_asset_url(url: str) -> bool:
    parts = urlsplit(url)
    return (
        parts.scheme == "https"
        and parts.netloc == "open.spotifycdn.com"
        and re.fullmatch(r"/cdn/build/web-player/[A-Za-z0-9~._-]+\.js", parts.path) is not None
        and not parts.query
        and not parts.fragment
    )


def player_bundle_urls(html: str) -> list[str]:
    parser = ScriptSources()
    parser.feed(html)
    urls = sorted({url for url in parser.urls if public_asset_url(url)})
    if not any(re.search(r"/web-player\.[A-Za-z0-9]+\.js$", url) for url in urls):
        raise ValueError("Spotify's desktop web-player bundle was not found in its public homepage")
    return urls


def extract_operations(source: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for name, kind, digest in DESCRIPTOR_RE.findall(source):
        if name not in WANTED_OPERATIONS or kind != "query":
            continue
        digest = digest.lower()
        if name in found and found[name] != digest:
            raise ValueError(f"Conflicting hashes for {name} in one public asset")
        found[name] = digest
    return found


def literal_table(text: str) -> dict[str, str]:
    quoted_keys = re.sub(r'(?<=[{,])(\s*)(\d+)\s*:', r'\1"\2":', text)
    return json.loads(quoted_keys)


def named_chunk_urls(source: str, bundle_url: str) -> dict[str, str]:
    tables = list(TABLE_RE.finditer(source))
    result: dict[str, str] = {}
    for names_match, hashes_match in zip(tables, tables[1:]):
        if hashes_match.start() - names_match.end() > 150:
            continue
        if not JS_SUFFIX_RE.match(source[hashes_match.end():hashes_match.end() + 100]):
            continue
        names = literal_table(names_match.group())
        hashes = literal_table(hashes_match.group())
        for chunk_id, name in names.items():
            if name not in CHUNK_NAMES:
                continue
            digest = hashes.get(chunk_id, "")
            if not re.fullmatch(r"[0-9a-f]{8,64}", digest):
                raise ValueError(f"Missing or invalid public chunk digest for {name}")
            url = urljoin(bundle_url, f"{name}.{digest}.js")
            if not public_asset_url(url):
                raise ValueError(f"Unexpected chunk URL for {name}")
            if name in result and result[name] != url:
                raise ValueError(f"Conflicting JavaScript chunks for {name}")
            result[name] = url
    return result


def fetch(url: str) -> bytes:
    if url != HOME_URL and not public_asset_url(url):
        raise ValueError("Only Spotify's public homepage and player JavaScript may be fetched")
    request = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urlopen(request, timeout=30) as response:
        final_url = response.geturl()
        if final_url != HOME_URL and not public_asset_url(final_url):
            raise ValueError("Unexpected redirect while fetching a public Spotify asset")
        body = response.read(MAX_ASSET_BYTES + 1)
    if len(body) > MAX_ASSET_BYTES:
        raise ValueError("Public Spotify asset exceeds the size limit")
    return body


def collect(fetch_asset=fetch) -> dict:
    sources: list[dict] = []
    operations: dict[str, dict] = {}

    def read(url: str) -> str:
        body = fetch_asset(url)
        sources.append({"url": url, "sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body)})
        return body.decode("utf-8")

    homepage = read(HOME_URL)
    chunks: dict[str, str] = {}

    def scan(url: str) -> str:
        source = read(url)
        for name, digest in extract_operations(source).items():
            previous = operations.get(name)
            if previous and previous["hash"] != digest:
                raise ValueError(f"Conflicting hashes for {name}; manifest was not replaced")
            operations.setdefault(name, {"hash": digest, "sources": []})["sources"].append(url)
        return source

    for url in player_bundle_urls(homepage):
        source = scan(url)
        for name, chunk_url in named_chunk_urls(source, url).items():
            if name in chunks and chunks[name] != chunk_url:
                raise ValueError(f"Conflicting bundle maps for {name}")
            chunks[name] = chunk_url
    missing_chunks = CHUNK_NAMES - chunks.keys()
    if missing_chunks:
        raise ValueError(f"Required public chunks missing: {', '.join(sorted(missing_chunks))}")
    for name in sorted(chunks):
        scan(chunks[name])
    missing = REQUIRED_OPERATIONS - operations.keys()
    if missing:
        raise ValueError(f"Required persisted operations missing: {', '.join(sorted(missing))}")
    return {
        "endpoint": ENDPOINT,
        "captured_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "provenance": "Extracted from public Spotify web-player assets; no authenticated requests were made.",
        "sources": sources,
        "operations": dict(sorted(operations.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "config" / "operations.json")
    args = parser.parse_args()
    try:
        manifest = collect()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_suffix(args.output.suffix + ".tmp")
        temporary.write_text(json.dumps(manifest, indent=2) + "\n")
        temporary.replace(args.output)
    except (OSError, ValueError) as error:
        print(f"Operation refresh failed: {error}", file=sys.stderr)
        return 1
    print(f"Saved {len(manifest['operations'])} read-only operations to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
