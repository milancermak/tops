# Tops playback engine

A macOS native playback helper using upstream librespot and Rodio/CoreAudio. It runs only while the app owns its process. No Spotify desktop process, web renderer, or developer-dashboard registration is involved.

The dependency is pinned to upstream commit `939dc5ee9d833e1980f9495241219d9d4868a061`. `Cargo.lock` also fixes the transitive dependency versions. This is a prototype: live authentication, audio and sleep/wake recovery need account testing.

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

Replies are `{"id":1,"result":{...}}` or `{"id":1,"error":"..."}`. Unknown or unauthenticated commands return an error. Malformed JSON uses `id:null`.

`authenticate` reuses cached login when possible, otherwise opens Spotify's browser login using PKCE and a state-checked loopback callback (three-minute timeout). Result: `{connected,username,device_id}`. It does not automatically take over playback from another device; `play` activates the local Tops device.

`status` and `playback` events contain `{connected,is_playing,position_ms,track_uri?,duration_ms?,title?,artist?,image_url?,volume_percent?}`. Position events arrive once per second during playback. Other events are `authentication` with `{state:"waiting_for_browser"}`, `connection` with `{connected:false}`, and `error` with `{message}`. Internal volume starts at 100 percent (unity gain), leaving the app's slider to control macOS output volume. This must be set in `ConnectConfig`: librespot ignores queued `volume` commands until the device is active. The protocol's `volume` command remains available for active playback, including the live check's low-volume test.

`partnerAuthContext` returns `{access_token,client_token,client_id,device_id,expires_at,token_kind:"desktop_oauth"}` for Pathfinder. Its bearer is the **original desktop OAuth grant**, refreshed when needed and paired with the session's existing client token. This is a first-party desktop grant, not a dashboard Web API grant.

Optional parameters `{ "force_refresh": true }` force one OAuth refresh even if the cached bearer has not expired. This never opens a browser. The caller may use it for one retry after HTTP 401; it must not loop or refresh in response to HTTP 403. A revoked refresh grant reports an error requiring a new sign-in.

`authContext` remains separate and returns the same fields with `token_kind:"login5"`. Its bearer comes from the session's **Login5 token**; it remains available for distinguishing native streaming/session authorization during diagnostics. The app should use `partnerAuthContext` for Pathfinder requests.

**Both responses contain credentials, not diagnostic output.** Keep them inside the app-owned pipe, never print or persist them in logs. `expires_at` is Unix seconds. The engine owns desktop OAuth refresh, caches replacement refresh tokens atomically, and serializes refreshes through its request loop. Call `partnerAuthContext` again when partner authorization needs renewing. Neither method provides a public Web API token.

No upstream logger is installed because upstream trace logs can include credentials. The parent must likewise avoid logging raw protocol replies.

After a confirmed transition from playing to paused, the engine asks the macOS allocator to release unused pages through `malloc_zone_pressure_relief(NULL, 0)`. This runs on a blocking control worker after releasing the playback-state lock, with a fresh state check to skip cleanup if playback already resumed. It does not run at authentication, on repeated paused/seek events, on a timer, or in the audio callback. Live allocations, decoder state, bitrate and gapless playback are unchanged.

`trimMemory` also remains available as an explicit idle/paused profiling command returning `{released_bytes}`; it refuses while playing. The allocator can reduce physical footprint while reporting zero released bytes, so measure process footprint rather than treating this return value as the amount reclaimed.

## Offline verification

```sh
python3 tests/protocol_smoke.py target/release/tops-engine
```

This checks JSON framing, both authorization methods' error responses before login, private cache permissions, stable device identity and clean shutdown. `cargo test --release --locked` additionally checks OAuth callback state validation, that token-service errors do not echo credentials, and that the partner method routes to the original desktop grant rather than Login5. These tests do not open a browser or contact Spotify.
