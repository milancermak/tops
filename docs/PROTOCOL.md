# Spotify private protocol evidence

Run `python3 tools/refresh_operations.py` from the repository, then rebuild the
app so its bundled `config/operations.json` is updated. This uses only Python's
standard library and unauthenticated requests to Spotify's public web player.
It records each asset URL, SHA-256 digest, and size. It downloads no music and
never reads browser profiles, passwords, cookies, or existing Spotify credentials.

The extractor reads operation descriptors and literal webpack chunk tables as
data. It never evaluates JavaScript. It checks the browse, section, and search
chunks as well as the initial player bundles. Missing required operations or
conflicting hashes stop the refresh before replacing the existing manifest.
Offline parser checks: `python3 -m unittest discover -s tests -p 'test_refresh_operations.py' -v`.

The operation hashes are implementation details, not a public API contract.
The checked-in manifest was fetched successfully on September 27, 2026. That
proves the operations are present in the served client; it does not prove an
authenticated account request or playback has succeeded.

## Personalized hub request

Spotify's public player redirects `/made-for-you`, `/daily-mix-hub`, and the
legacy `/genre/made-for-x-hub` routes to
`/genre/0JQ5DAt0tbjZptfcdMSKl3`. Its browse router converts the 22-character ID
into `spotify:page:0JQ5DAt0tbjZptfcdMSKl3`.

POST to the manifest's `endpoint`, with an authenticated Spotify session bearer
and `client-token`, and a JSON body with `operationName`, `variables`, and
`extensions.persistedQuery: {version: 1, sha256Hash: <manifest hash>}`.

`browsePage` variables observed in the official client:

```json
{
  "uri": "spotify:page:0JQ5DAt0tbjZptfcdMSKl3",
  "pagePagination": {"offset": 0, "limit": 10},
  "sectionPagination": {"offset": 0, "limit": 10},
  "browseEndUserIntegration": "INTEGRATION_WEB_PLAYER",
  "includeEpisodeContentRatingsV2": false
}
```

The response is `data.browse`, with `__typename: BrowseSectionContainer`.
Its `header.title.transformedLabel` is the page heading; `sections.items` is the
ordered shelf list. Continue page loading using `sections.pagingInfo.nextOffset`.
Shelf headings use `data.title.transformedLabel`, cards use `sectionItems.items`,
and the shelf's URI identifies its own continuation request.

Use `browseSection` to fetch a shelf beyond its initial cards:

```json
{
  "uri": "spotify:section:<URI returned by browsePage>",
  "pagination": {"offset": 0, "limit": 20},
  "browseEndUserIntegration": "INTEGRATION_WEB_PLAYER",
  "includeEpisodeContentRatingsV2": false
}
```

Its response is `data.browseSection` with `__typename: BrowseSection`; continue
using `sectionItems.pagingInfo.nextOffset`. Use the returned URI verbatim rather
than constructing it from a display name. Stop on null or a non-increasing offset.

## Home and home-section requests

`home` is the full account homepage, separate from the Made for You browse hub.
Observed variables: `homeEndUserIntegration: INTEGRATION_WEB_PLAYER`, local IANA
`timeZone`, `sp_t: ""`, `facet: ""`, `sectionItemsLimit: 10`, and
`includeEpisodeContentRatingsV2: false`. Its shelves are under
`data.home.sectionContainer.sections.items`.

`homeSection` uses `uri`, the same integration/timezone/empty `sp_t` fields,
`sectionItemsOffset: 0`, `sectionItemsLimit: 20`, and the same ratings boolean.
Its response is `data.homeSections`, with `__typename: HomeSectionCollection`,
containing `sections[0]` with `__typename: HomeSection`. Continue using
`sectionItems.pagingInfo.nextOffset`.

The web client uses the `sp_t` cookie if present and the empty string otherwise.
An OAuth access token is not this field. Current requests do not require the
old third-party IP-geolocation request or its `country` parameter.

## Search request and entity wrappers

The served search chunk passes the following fields to `searchDesktop`. Some
values vary by feature flag. These are conservative values for music search:

```json
{
  "searchTerm": "Miles Davis",
  "offset": 0,
  "limit": 20,
  "numberOfTopResults": 5,
  "includeAudiobooks": false,
  "includeArtistHasConcertsField": false,
  "includePreReleases": false,
  "includeAlbumPreReleases": false,
  "includeAuthors": false,
  "includeEpisodeContentRatingsV2": false,
  "isPrefix": null,
  "sectionFilters": ["GENERIC"]
}
```

`clientFeatures` is absent normally; clicking a query suggestion can supply
`[{"key": "clicked_query_suggestion", "value": 1}]`. The client also has a newer
`searchTopResultsList` UI route; that operation uses `query` instead of
`searchTerm`, and is not the operation used by this prototype. Its variable
adapter mentions optional `includeLocalConcertsField`. The obsolete
`includeRatings` and `includePodcastChapters` fields do not appear in the
current search request.

This list records what the current client sends. The persisted GraphQL query
body is not shipped in these assets, so whether each field is non-null/required
cannot be established from its TypeScript callsite alone. This request shape was
subsequently validated by live native search on September 27, 2026; its formal
required/nullability contract remains undocumented.

The `searchDesktop` response uses `data.searchV2`:

| Collection | Entity location inside each item |
| --- | --- |
| `tracksV2.items` | `item.data` |
| `albumsV2.items` | `data` |
| `artists.items` | `data` |
| `playlists.items` | `data` |
| `topResultsV2.itemsV2` | `item.data` |

Tracks expose `name`, `uri`, `artists.items[].profile.name`,
`albumOfTrack.coverArt.sources`, and `duration.totalMilliseconds`. Albums expose
`name`, `uri`, `artists.items[].profile.name`, and `coverArt.sources`. Artists
use `profile.name` and `visuals.avatarImage.sources`. Playlists use `name`,
`uri`, `description`, and `images.items[].sources`.

Browse/home cards have another wrapper layer:
`sectionItems.items[].content.data`. The official browse renderer switches on
`content.__typename` (for example `PlaylistResponseWrapper`) and then passes
`content.data` to a renderer switching on `__typename: Playlist`. The payload
includes the playlist's `uri`, `name`, `description`, `images`, and `ownerV2`.
The current prototype's `content.data` path therefore matches the official
renderer. Unavailable `NotFound`, `GenericError`, and `RestrictedContent`
entities should be ignored rather than converted into music cards.

## Collection detail requests (2026-09-27)

Opening an album, playlist or artist is a read-only metadata action. It does not
send a playback command. `SpotifyAPI.collection(_:offset:)` returns collection
metadata, ordered track rows, the server's total count when present, and a next
offset. Each row has its actual track URI, artist, duration and playability.
Duplicate playlist tracks keep distinct position-based row IDs.

The [official player bundle](https://open.spotifycdn.com/cdn/build/web-player/web-player.da8b87c8.js)
contains all three descriptors and callsites: playlist adapter methods
`getPlaylistInternal`/`getPlaylistContents`, album request module `28372` with
descriptor module `13180`, and artist request module `24210`. Current hashes are
recorded with the bundle's checksum in `config/operations.json`:

| Operation | Persisted query hash |
| --- | --- |
| `fetchPlaylist` | `243c0ba2736f16da721e3a227004bbcdb8df6c846f198bd478172e00aa1faf42` |
| `getAlbum` | `6a74b456cd1735c9193d9e8ec8cc5184cad7ce13572210315229db3975964361` |
| `queryArtistOverview` | `9f8134ef565e78621f1e1793555bd6633c5ac144ae0f89604ed3ae3f80b3c8e6` |

Playlist variables:

```json
{
  "uri": "spotify:playlist:<id>",
  "offset": 0,
  "limit": 50,
  "enableWatchFeedEntrypoint": false,
  "includeEpisodeContentRatingsV2": false
}
```

The response is `data.playlistV2` with `__typename: Playlist`. Its
`content.items[].itemV2.data` contains `Track` objects with
`trackDuration.totalMilliseconds`, `artists.items[].profile.name`,
`albumOfTrack.coverArt.sources` and `playability.playable`. Null, local-file,
episode and unavailable entities do not become playable music rows.
`content.pagingInfo` exposes `offset` and `limit`; the live response has no
`nextOffset`. Continue using requested offset plus the number of **raw** rows
when that is below `content.totalCount`. Filtering rows must not change the
pagination offset. An explicit null next offset, when supplied, ends paging.

Album variables are `{"uri":"spotify:album:<id>","offset":0,"limit":50,"locale":""}`.
The response is `data.albumUnion` with `__typename: Album` and
`tracksV2: {items, totalCount}`. Rows contain `track`, whose duration uses
`duration.totalMilliseconds`; its `__typename` is absent in the observed
response. Album art is supplied by `coverArt.sources` on the parent. The same
offset/raw-row-count calculation handles additional album pages. The exported
`queryAlbumTracks` descriptor shares the `getAlbum` hash; this app uses
`getAlbum` for both initial and subsequent pages.

Artist variables are `{"uri":"spotify:artist:<id>","locale":"","preReleaseV2":false}`.
The response is `data.artistUnion` with `__typename: Artist`; popular tracks are
under `discography.topTracks.items[].track`. The observed page provides ten
tracks and no total or paging fields. Tops presents these as top tracks and
does not invent a complete discography or continuation request.

Authorized live requests using Tops' saved desktop OAuth grant and the tested
desktop headers succeeded without launching another helper or starting music:

- All Out 90s playlist: offsets 0 and 50 each returned HTTP 200 and 50 rows,
  with total count 150 and matching returned offsets.
- Random Access Memories album: HTTP 200, 13 tracks with duration/playability.
- Daft Punk artist: HTTP 200, ten top tracks with duration/playability.

These probes omitted the client token, consistent with the earlier diagnostic;
the app continues supplying its engine-owned client token. Only schema names,
field types and counts were logged. Six offline Swift tests cover these wrappers,
duplicate/unavailable tracks, offsets, final-page behavior, request variables and
unsupported-item handling. A separate bounded feed read returned no card named
`DJ` or `Your DJ`; DJ behavior was therefore not validated. Unsupported or
unavailable collections report an error or an empty music list, never implicit
playback.

## Evidence and attribution

The [official player bundle](https://open.spotifycdn.com/cdn/build/web-player/web-player.da8b87c8.js)
contains route aliases, conversion from browse IDs to page URIs, operation
descriptors, the home request, and the integration enum mappings. The
[official browse chunk](https://open.spotifycdn.com/cdn/build/web-player/browse-v2.fe930758.js)
contains page/section variables, pagination, and response field access. The
[official home-section chunk](https://open.spotifycdn.com/cdn/build/web-player/home-v2-section.170ae6e7.js)
contains the section request; the
[official search chunk](https://open.spotifycdn.com/cdn/build/web-player/xpui-routes-search.96d81afe.js)
contains search requests. These immutable asset names are also recorded with
digests in the manifest. The code here extracts protocol identifiers; it does
not redistribute Spotify's player bundles.

Independent implementation evidence: [Psst's merged Login5 authentication repair](https://github.com/jpochyla/psst/pull/745)
states that a session Login5 bearer plus client token restored its homepage
after developer OAuth tokens stopped being accepted. Its
[home-section implementation](https://github.com/jpochyla/psst/blob/3c3621aa79f820c737dd899e7e359b1359292466/psst-gui/src/webapi/client.rs#L1483)
uses the older `spotify:section:0JQ5DAUnp4wcj0bCb3wh3S` shelf. This is narrower
than the full browse hub. The public-asset descriptor extraction approach was
cross-checked against
[libspot's xpuiops tool](https://github.com/pyrorhythm/libspot/blob/a0997065ab2ad9876bf3f0527c93230839e3c37d/cmd/xpuiops/main.go).
The Python extractor is independently implemented.


## Authenticated HTTP 403 diagnosis (2026-09-27)

The first prototype completed sign-in but its Made for You request returned
HTTP 403. An explicitly authorized account diagnostic compared requests without
logging tokens or personalized content. All requests used the same operation,
hash and variables described above. The initial Python requests inherited
urllib's default User-Agent.

| Bearer and request context | Explicit User-Agent | Client token | Result |
| --- | --- | --- | --- |
| Login5, web origin | None; Python default | Present | 403, `Client/request not allowed` |
| Login5, desktop headers | None; Python default | Present | 403, `Client/request not allowed` |
| Desktop OAuth, desktop headers | None; Python default | Present | 403, `Client/request not allowed` |
| Same desktop OAuth, desktop headers | Spotify desktop | Same token | 200, `BrowseSectionContainer`, nine shelves |
| Same desktop OAuth, desktop headers | Browser | Same token | 200, `BrowseSectionContainer` |
| Same desktop OAuth, desktop headers | Spotify desktop | Absent | 200, `BrowseSectionContainer` |
| Login5, desktop headers | Spotify desktop | Present | 200, `BrowseSectionContainer` |

The desktop User-Agent was `Spotify/1.2.52.442 OSX/0 (Tops/0.1)`. The browser
comparison used Chrome 132 on macOS. Desktop headers were `App-Platform:
OSX_ARM64`, `Origin: https://xpui.app.spotify.com`, and matching `Referer`.

Changing only the User-Agent turned the saved desktop OAuth request from 403 to
200. Token type and client-token construction were therefore not the cause of
that reproduced failure. This does not establish that every non-default
User-Agent or every token combination will be accepted. The working app keeps
its client token and explicitly sets the tested desktop User-Agent.

The native adapter obtains its desktop OAuth bearer via `partnerAuthContext`.
Login5 remains separate for playback. OAuth refresh stays serialized inside the
engine. This probe proved the personalized response; the following validation
separately exercised the native UI and streaming pipeline.

This follows the current [Spotifly request implementation](https://github.com/ralph/Spotifly/blob/main/Spotifly/PartnerAPI/PartnerAPI.swift)
and its [documented single-grant probes](https://github.com/ralph/Spotifly/blob/main/plans/single-grant-partner-api.md).
A dashboard Web API OAuth token and a desktop OAuth token are different: evidence
that the former fails on Pathfinder does not show that the latter fails.

`tools/diagnose_api.py` performs a bounded live comparison with Tops' saved sign-in
when the user authorizes it. By default it makes two browse requests, varying only
the User-Agent; repeat `--variant` to select additional named comparisons. It
contacts only Spotify, never starts music, and prints only status, schema, counts
and sanitized error summaries. Credentials and full responses stay out of output.
Its transient credential copy is stored in a private temporary directory and
removed on exit. It rejects near-expiry OAuth tokens and does not offer a refresh
probe: refresh through Tops so a rotated refresh token is saved in the original
session. This diagnostic is not run automatically by the app or tests.

## Native app and streaming verification (2026-09-27)

The final native UI rendered nine shelves and was scrolled to Daily Mix 1–6,
Release Radar and Discover Weekly. Search for `Daft Punk Get Lucky` returned
results. Track streaming produced metadata, duration and advancing progress;
GUI pause, seek/resume, On Repeat playlist playback, next and previous were
observed. The rebuilt app was relaunched after its child-process lifecycle fix,
and the feed and playback events were verified again.

The opt-in `tools/test_live_playback.py --playback` check passed authentication,
search, playback progress, a two-second paused hold, a seek to 15,000 ms, resume,
final pause confirmation and termination of its own engine. The final GUI test
session was left paused at 10% volume. No human listening confirmation was
recorded, so these results establish streaming and control behavior rather than
perceived audio quality. OAuth refresh is tested offline, not through a live
token-expiry cycle.

Current test counts and later UI verification are in the README. Subsequent
memory work reduced the single-run playing physical-footprint sample from
104.3 to 71.06 MiB for UI plus helper. This is distinct from RSS and does not
establish a repeatable benchmark; [the profiling report](MEMORY.md) records the
exact comparisons and remaining measurement gaps.
