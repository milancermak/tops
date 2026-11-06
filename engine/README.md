# Tops playback engine

A macOS native playback helper using upstream librespot and Rodio/CoreAudio. It runs only while the app owns its process. No Spotify desktop process, web renderer, or developer-dashboard registration is involved.

The dependency is pinned to upstream commit `939dc5ee9d833e1980f9495241219d9d4868a061`.
Its core crate has a [small local OAuth provider patch](vendor/README.md), with
source and license included so fresh checkouts build without external patches.
`Cargo.lock` also fixes the transitive dependency versions. This is a prototype:
live authentication, audio and sleep/wake recovery need account testing.

## Build

Use a current stable Rust toolchain; Rust 1.98.1 is verified. The crate's language
minimum is Rust 1.85, but locked dependencies may require a newer compiler. From
the repository root:

```sh
cargo build --release --locked --manifest-path engine/Cargo.toml
```

The output is `engine/target/release/tops-engine`. To build the complete macOS app,
follow the [top-level build instructions](../README.md#build). When working inside
`engine/`, ordinary `cargo build --release --locked` works; the commands below
assume that directory.

## Process protocol

Launch with `tops-engine --data-dir /absolute/path`. The data directory has mode 0700; credentials are written atomically with mode 0600. The app should choose its own Application Support directory. Cached login and a stable device ID survive app relaunches. Audio is not cached on disk.

The parent writes one JSON object per line to stdin and reads one JSON object per line from stdout. The helper emits `{"event":"ready","data":{"version":"0.1.0"}}` immediately. Closing stdin or sending `shutdown` stops it.

Requests:

```json
{"id":1,"method":"authenticate","params":{}}
{"id":2,"method":"status","params":{}}
{"id":3,"method":"play","params":{"uri":"spotify:track:TRACK_ID"}}
{"id":4,"method":"seek","params":{"position_ms":15000}}
{"id":5,"method":"volume","params":{"percent":50}}
{"id":6,"method":"partnerAuthContext","params":{}}
{"id":7,"method":"shutdown","params":{}}
```

`pause`, `resume`, `next` and `previous` take empty parameters. `play` also accepts Spotify album, artist, playlist and episode URIs. `seek` is absolute milliseconds. Mutation replies acknowledge queued commands; subsequent events establish actual playback.

`restore` accepts `{track_uri, context_uri?, position_ms, start_playing}` after
authentication. The app sends it on an explicit transport action after reconnecting.
The helper uses `LoadRequestOptions` and `PlayingTrack::Uri` from the pinned
librespot 0.8.0 Git revision `939dc5e`. It loads paused at the requested position,
confirms the requested URI in the current `PlayerEvent::Paused`, then resumes if
requested. The result `{context_restored}` reports whether the native collection
was loaded. If the context cannot resolve the saved track, the helper tries that
track on its own. A track unavailable in both loads returns an error. Duplicate
track occurrences follow librespot's URI matching. This uses the same native
session and credentials as `play`. See the [pinned load options](https://github.com/librespot-org/librespot/blob/939dc5ee9d833e1980f9495241219d9d4868a061/connect/src/model.rs),
[Connect implementation](https://github.com/librespot-org/librespot/blob/939dc5ee9d833e1980f9495241219d9d4868a061/connect/src/spirc.rs)
and [0.8.0 release notes](https://github.com/librespot-org/librespot/releases/tag/v0.8.0).
The Rust test verifies confirmation of the saved track and rejection of a
different track. Swift tests cover restart, checkpoint isolation by account,
and standalone tracks. A native fixture exercised quit, reopen, Play and Next
with a playlist. Live Spotify context resolution on restore remains unverified.

Replies are `{"id":1,"result":{...}}` or `{"id":1,"error":"..."}`. Unknown or unauthenticated commands return an error. Malformed JSON uses `id:null`.

`authenticate` reuses the saved OAuth grant when possible, otherwise opens
Spotify's browser login using PKCE and a state-checked loopback callback
(three-minute timeout). The current grant also establishes the access-point
session, keeping playback and browsing on the same account even if older cached
playback credentials exist. Result: `{connected,username,device_id}`. It does not
automatically take over playback from another device; `play` activates the local
Tops device.

`status` and `playback` events contain `{connected,is_playing,position_ms,track_uri?,duration_ms?,title?,artist?,image_url?,volume_percent?}`. Position events arrive once per second during playback. Other events are `authentication` with `{state:"waiting_for_browser"}`, `connection` with `{connected:false}`, and `error` with `{message}`. Internal volume starts at 100 percent (unity gain), leaving the app's slider to control macOS output volume. This must be set in `ConnectConfig`: librespot ignores queued `volume` commands until the device is active. The protocol's `volume` command remains available for active playback, including the live check's low-volume test.

`playback` events also include `position_confirmed`, which distinguishes actual
play, pause, seek and position notifications from loading or metadata changes.
The Swift checkpoint only records confirmed positions with track metadata and
a known duration. It keeps no credentials or audio.

`partnerAuthContext` returns `{access_token,client_token,client_id,device_id,expires_at,token_kind:"desktop_oauth"}` for Pathfinder. Its bearer is the **original desktop OAuth grant**, refreshed when needed and paired with the session's existing client token. This is a first-party desktop grant, not a dashboard Web API grant.

Optional parameters `{ "force_refresh": true }` force one OAuth refresh even if the cached bearer has not expired. This never opens a browser. The caller may use it for one retry after HTTP 401; it must not loop or refresh in response to HTTP 403. A revoked refresh grant reports an error requiring a new sign-in.

`authContext` remains available for native playback authorization and returns
the same fields with `token_kind:"desktop_oauth"`. The playback token provider
uses the original desktop OAuth grant directly, rather than exchanging the
access-point credential with Login5. The app uses `partnerAuthContext` for
Pathfinder requests.

**Both responses contain credentials, not diagnostic output.** Keep them inside
the app-owned pipe, never print or persist them in logs. `expires_at` is Unix
seconds. The engine owns desktop OAuth refresh and caches replacement refresh
tokens atomically. A shared asynchronous mutex serializes browsing and playback
refreshes, so only one request rotates the grant at a time. Background playback
refresh never opens a browser and propagates authorization failures rather than
silently changing token sources. Call `partnerAuthContext` again when partner
authorization needs renewing. Neither method provides a public Web API token.

Connection diagnostics use a narrowly filtered logger: only known service names
from librespot's HTTP request-start messages are retained, while every other
upstream log is discarded. Tokens, usernames, device IDs, headers, response
bodies and raw URLs are never included. The parent must likewise avoid logging
raw protocol replies.

Each playback connection attempt emits a `connection_diagnostic` event and
atomically replaces `connection-diagnostic.json` in the engine's private data
directory (mode 0600). For the app this is
`~/Library/Application Support/Tops/session/connection-diagnostic.json`.
The report contains a start timestamp, elapsed milliseconds, stage, outcome,
numeric HTTP status when available, a safe error category, and up to 16 recent
request service names with timings. It covers playback setup after OAuth has
succeeded; an earlier browser sign-in or OAuth failure does not replace it.

Client-token acquisition is identified separately and its cached result is reused
by librespot's normal connection setup. Failures in later session setup list
recently requested services as clues, not proof that the last request failed.
Both stages share the existing 35-second connection timeout. No new retries are
added. The error banner includes the stage and HTTP status; temporary sessions
are shut down on failure or timeout. Only the latest report is retained locally,
and nothing is uploaded.

After a confirmed transition from playing to paused, the engine asks the macOS allocator to release unused pages through `malloc_zone_pressure_relief(NULL, 0)`. This runs on a blocking control worker after releasing the playback-state lock, with a fresh state check to skip cleanup if playback already resumed. It does not run at authentication, on repeated paused/seek events, on a timer, or in the audio callback. Live allocations, decoder state, bitrate and gapless playback are unchanged.

`trimMemory` also remains available as an explicit idle/paused profiling command returning `{released_bytes}`; it refuses while playing. The allocator can reduce physical footprint while reporting zero released bytes, so measure process footprint rather than treating this return value as the amount reclaimed.

## Offline verification

```sh
python3 tests/protocol_smoke.py target/release/tops-engine
cargo test --release --locked -p tops-engine
cargo test --release --locked -p librespot-core --lib external_token_provider_tests
```

This checks JSON framing, both authorization methods' error responses before
login, private cache permissions, stable device identity and clean shutdown.
`cargo test --release --locked` additionally checks OAuth callback validation,
credential-free diagnostics and shared OAuth refresh behavior. These tests do
not open a browser or contact Spotify.

The September 29 OAuth playback repair passed 14 engine tests and four provider
tests. Live verification covered connection, forced OAuth renewal shared by
playback and browsing, search, track metadata and advancing playback, pause,
seek, resume, and graceful shutdown. Authenticated stdin EOF also exited cleanly.
The complete app was rebuilt and signed. Expiry-driven refresh is covered by
mocked concurrent requests; the live test exercises an explicit refresh rather
than waiting for a token's natural expiry.
