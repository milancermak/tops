# Tops

A small native macOS Spotify client prototype for a personal Premium account.
SwiftUI renders the interface; a Rust/librespot child process streams directly to
CoreAudio. Spotify.app does not need to run. No embedded browser engine is used
for the interface or audio. Spotify sign-in opens in your normal browser.

## Current state

**The native app now signs in, renders the real Made for You feed, searches, and
streams with working playback controls.** This was verified on the user's Premium
account on an Apple Silicon Mac running macOS 15.7.4. The feed displayed nine
shelves, including Daily Mix 1–6, Release Radar and Discover Weekly. Search,
track and playlist playback, pause/resume, seek, next and previous were exercised.

The interface uses one native titlebar with Back and Home on the left, search on
the right, and a settings cog at the far right. The center stays empty. Cover grids align
at the top and reserve consistent title/subtitle space. Playlist and album cards
open track lists; artist cards open top tracks. Opening a card does not start
playback. Space toggles playback when the window has focus, while spaces typed
into search remain ordinary text.

The original HTTP 403 was isolated to User-Agent filtering; adding the tested
Spotify desktop User-Agent made the same saved-token request succeed. The app
also includes a bounded 401 refresh and tested child-process lifecycle handling.
Streaming and progress were verified, but no human listening confirmation was
recorded. This is a working personal prototype with private interfaces that
Spotify can change without notice.

## Try it

First [build from source](#build); `dist/Tops.app` is generated locally and is not
included in the repository. Open it, then choose **Connect Spotify**. Sign in on Spotify's own
website and return to Tops. It requires Premium. There is no developer-dashboard
registration or client secret to enter. Playback starts only when you choose music.

```sh
open dist/Tops.app
```

The app has two sections:

- **Made for You:** reads Spotify's actual internal personalized browse hub;
  **Show more** pages through additional items in a shelf. The Home button returns
  here from search or collection details. Discover New Music and Your Daily Mixes
  lead the page; Watch What You Love is hidden.
- **Search:** searches songs, albums, artists and playlists, with the first 20
  results per category. Search starts 400ms after the last edit; Return submits
  immediately. The first seven songs appear with larger covers and a centered
  **Expand** control, followed by Artists, Playlists, and Albums. Click a song to play it;
  click a playlist, album or artist to inspect its songs first.

Collection covers animate from the clicked card to the top-left detail header in
240ms, with an immediate image handoff that avoids a second fade;
Reduce Motion skips the movement. Collection details show track names, artists and durations, with **Show more
songs** for additional playlist/album pages. Back restores the preceding search
or Made for You view. **Play** starts the collection's playback queue; clicking
an individual row currently starts that song on its own. Empty collections do
not enable Play. Artist details contain Spotify's top tracks, not a full discography.

The player supports play/pause, previous/next, seek and macOS system volume.
The volume slider and system output volume follow each other, including mute and
output-device changes. Devices without writable system volume disable the slider.
Plain Space toggles
play/pause outside text editing and focused native controls; key repeats and
modified Space presses are ignored. Cmd-F focuses search; Cmd-R refreshes
recommendations. Closing the window quits the app and its playback process.
Search pagination, automatic reconnect, media keys, offline playback, shuffle
and repeat are not implemented.

The bottom player arranges track information, transport buttons, progress and
volume in a single row, with both sliders on the same horizontal line. Its 42pt
cover matches the playlist song covers; all artwork starts at the same 28pt inset.

## How Made for You works

See [the exact protocol evidence](docs/PROTOCOL.md). The public Web API is not used.

The current full hub is `spotify:page:0JQ5DAt0tbjZptfcdMSKl3`, fetched via Spotify's
private Pathfinder `browsePage` operation. Individual shelves use `browseSection`;
`homeSection` provides an actual personalized shelf fallback when the hub returns
no readable music. A desktop OAuth bearer, Spotify client token, desktop request
headers and an explicit User-Agent authenticate Pathfinder requests. Login5
remains separate for playback services. Tokens only pass between the app and its
private child process.

Public operation hashes are recorded in `config/operations.json` with exact CDN
source URLs, capture time and SHA-256 checksums. Refresh them without signing in:

```sh
python3 tools/refresh_operations.py
./scripts/build-app.sh --skip-engine
```

This handles changed persisted-query identifiers, not arbitrary schema or
protocol changes. The extractor reads JavaScript as text; it does not execute it.
No scraping of browser cookies, credentials, or installed Spotify app data occurs.

## Build

### Prerequisites

- **macOS 14 or newer.** The UI and audio backend use macOS frameworks; building
  on Linux or Windows is not supported. Apple Silicon has been tested; Intel
  builds have not been verified.
- **Xcode Command Line Tools with Swift 5.10 or newer.** Install them with
  `xcode-select --install` if needed, then check `swift --version`. The verified
  build environment uses Swift 6.2.4.
- **A current stable Rust toolchain**, including `cargo` and `rustc`, available
  in your shell. Rust 1.98.1 is the verified version. If needed, install Rust
  using [rustup](https://rustup.rs/), then open a new terminal. With an existing
  rustup installation, `rustup update stable` installs the current stable
  toolchain; use `RUSTUP_TOOLCHAIN=stable ./scripts/build-app.sh` if your default
  toolchain is older. The engine declares Rust 1.85 as its language minimum,
  but locked dependencies may require newer Rust.
- **Internet access** for the initial Rust dependency downloads. Spotify login
  and a Premium account are needed to use the app, but not to build or run the
  offline tests. No API keys or client secrets are required.
- **Python 3.9 or newer** for the Python tests and optional protocol tooling.
  Python is not required to build or run the app.

### Build and launch

From a fresh checkout:

```sh
git clone https://github.com/milancermak/tops.git
cd tops
./scripts/build-app.sh
open dist/Tops.app
```

Run the last two commands if you already have the source directory. The script
builds the Rust engine, compiles the Swift UI, generates the app icon, and bundles
everything into `dist/Tops.app`. The first build can take several minutes.
Rust dependency resolution is locked in `engine/Cargo.lock`; upstream librespot
is pinned to a specific Git revision in `engine/Cargo.toml`. No temporary paths
or files from the original development machine are required.

To rebuild only Swift and repackage an existing engine:

```sh
./scripts/build-app.sh --skip-engine
```

The script creates an ad-hoc signed local `dist/Tops.app`, not a notarized release.
Both binaries and the operation manifest are included, so the app can run without
Rust, Cargo or Python installed. The target architecture is the build Mac's.

The app icon comes from `assets/AppIcon.png`, a square image at least 1024 pixels
wide. Each build renders a rounded macOS silhouette with transparent padding,
then uses `sips` and `iconutil` to generate all standard icon sizes in
`.build/AppIcon.iconset` and package `.build/AppIcon.icns` in the app.
Run `./scripts/build-icon.sh` to regenerate just the icon.
Tops also loads the bundled icon on launch so the Dock and app switcher use the
current artwork even when macOS has cached an older build.

## Verification

Run these offline checks from the repository root after building. They do not
sign in to Spotify or start music. Use the same Rust toolchain as for the build.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox --cache-path .build/swiftpm-cache
python3 -m unittest discover -s tests -v
cargo test --locked --manifest-path engine/Cargo.toml
python3 engine/tests/protocol_smoke.py engine/target/release/tops-engine
```

Verified on September 28, 2026 with Swift 6.2.4 and Rust 1.98.1 on Apple Silicon:
a clean source-only copy built and passed app-signature verification; 49 Swift,
five Rust, and six Python tests passed, as did the engine protocol smoke check.
The clean build used cached dependency downloads but no existing build products.

### Working on Tops, including with an agent

The README commands are sufficient for a developer or coding agent with access
to a Mac and the prerequisites above. `Sources/Tops/` contains the Swift UI and
Spotify request code, `engine/src/` contains the Rust playback helper, and
`config/operations.json` holds the public operation manifest. Tests are in
`tests/` and `engine/tests/`; implementation notes are in `docs/`.

Start with the full build and offline checks above. `--skip-engine` is only for
subsequent Swift or resource changes after the engine has been built. Live login
requires the account owner to complete Spotify's browser sign-in; the optional
`tools/test_live_playback.py --playback` check starts real music and should only
be run deliberately. Keep local credentials and generated build files out of Git.

Sandboxed agents may need permission to run the build on the host: macOS
`iconutil` returned `Invalid Iconset` inside the agent sandbox during verification,
while the unchanged build succeeded outside it.

### Previous runtime verification

Verification on September 27, 2026:

- **Latest Swift run:** 49 tests passed after the UI/search/system-volume changes
  and Home shelf preferences.
  The earlier engine/tooling run passed five Rust tests and six Python tests;
  those components were not changed in this follow-up. Swift includes collection parsing and pagination, stale-request
  cancellation, keyboard focus policy, playback-update isolation, artwork handling
  and child-process lifecycle tests. Token refresh is covered offline;
  expiry-driven refresh has not been exercised live.
- **Native UI:** nine recommendation shelves rendered and scrolled correctly;
  search for `Daft Punk Get Lucky` returned results. Track streaming supplied
  metadata, duration and advancing progress. Pause, seek/resume, On Repeat
  playlist playback, next and previous were observed.
- **Live engine check:** `tools/test_live_playback.py --playback` passed
  authentication, search, advancing playback, a two-second pause hold, seeking
  to 15 seconds, resume, final pause confirmation and owned-engine shutdown.
- **Collection and keyboard follow-up:** On Repeat showed 24 tracks and Random
  Access Memories showed 13. Cards opened without starting playback, Back restored
  Search, and Home restored Made for You. Space paused and resumed playback;
  the final native search field received focus with Cmd-F, and typing `Daft Punk`
  (including its space) preserved active playback. Home resigned text-entry
  focus, after which Space paused the track. The final toolbar was visually
  checked for its breadcrumb title and top-right search placement, and covers
  were aligned across the row. Tops was left on Home, paused at 10% volume.
  Updated Home/detail screenshots are in `docs/ui-review-v2.html`.
- **UI/UX follow-up:** the rebuilt app returned Metallica results without Return,
  showed seven 56pt song covers and centered Expand, expanded/collapsed songs,
  and opened a playlist from a scrolled search into the top-right cover layout.
  Detail scrolling resumed after the transition and Back restored search.
  Lowering Tops' slider changed macOS Sound output volume from 43.75% to 33.75%;
  raising it in System Settings updated Tops back to 43.75%. No playback was
  started during these checks. New offline tests exercise debounce cancellation,
  obsolete responses/errors, volume notifications, mute, balance, output switching,
  unsupported outputs and listener cleanup. See `docs/UI.md` for the six-item mapping.

The **memory-optimization build profiled on September 27, before the subsequent
toolbar and collection-browser changes**, reduced observed playing footprint by
about **32%**, using the same feed/search/playback workflow before and after.
These single-run spot checks measure physical footprint in MiB, combining the
UI and helper; the latest interface has not been reprofiled:

| State | Before | Optimized |
| --- | ---: | ---: |
| Feed loaded and scrolled | 90.24 | 72.98 |
| Playing | 104.3 | 71.06 |
| Paused after playback | 104.3 | 71.02 |

These are separate launches, not a repeatable benchmark or a Spotify.app
comparison. Physical footprint differs from RSS. Startup latency, sustained CPU
use, long sessions and human-confirmed audio quality remain unmeasured.
See [the profiling report](docs/MEMORY.md) for
raw evidence, intermediate experiments and measurement limits. Audio remains
configured at 320 kbit/s with the existing playback buffers.

## Local data and limits

Credentials are stored under `~/Library/Application Support/Tops/session` in a
private directory (0700), with token files written atomically (0600). They are not
yet stored in Keychain. Do not share this folder. Audio disk caching is disabled.
No telemetry or analytics are sent by Tops itself; normal Spotify protocol traffic
still occurs through librespot. There is no account password collected by Tops.

Development overrides: `TOPS_ENGINE`, `TOPS_DATA_DIR`, `TOPS_OPERATIONS`.
These point to the helper binary, private credential directory and public operation
manifest respectively. Do not put tokens into environment variables or command
arguments. Authentication is unavailable to other applications over an IPC port;
the UI uses stdin/stdout pipes to its own child process.

This is an unofficial Spotify integration for personal experimentation. It is not
endorsed by Spotify and is not a promise of compliance with Spotify's terms or a
safe basis for distribution. The official Developer Policy restricts replacement
clients: https://developer.spotify.com/policy

## References and licenses

Tops source code is available under the [MIT License](LICENSE).

- Spotify public web-player assets are inspected as protocol evidence; their code
  is not bundled. Exact source attribution is in docs/PROTOCOL.md.
- librespot: https://github.com/librespot-org/librespot (MIT), pinned revision
  `939dc5ee9d833e1980f9495241219d9d4868a061`; its play_connect example informed the engine.
- Psst: https://github.com/jpochyla/psst (MIT), independently demonstrates internal
  personalized shelves and Login5 authentication.
- Spotifly: https://github.com/ralph/Spotifly (MIT), a reference for desktop PKCE and
  Swift plus Rust integration. Tops does not depend on or copy its bridge.

Third-party dependencies retain their individual licenses. The build script
produces a local, ad-hoc signed app; it does not produce a notarized release.
