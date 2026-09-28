# Native UI review — September 27, 2026

## Sign-in screen cleanup

The login screen omits the entire bottom playback bar and its divider. Both
return after connection, so the login content uses the full window height.

The disconnected screen hides toolbar search and disables Cmd-F. It keeps the
headline and sign-in footer, removes the Premium-account description, and uses
Spotify green (`#1DB954`) for the waveform and Connect button. The same explicit
color tints the playback-position and system-volume sliders throughout the
connected app.

Player metadata is shown only when connected with a current track. Otherwise its
245×42pt slot stays empty, preserving the position and height of playback controls,
including when a reconnect retains an old now-playing item in the model.

The release app was rebuilt and relaunched. Native accessibility and screenshot
checks confirmed the login screen has no playback controls or bottom divider.
The earlier cleanup verified the green waveform/Connect button and volume fill,
blank metadata slot, and disabled Cmd-F. The playback slider uses the same tint;
its filled state was not exercised because these checks stayed signed out.
System volume remained at 50 percent.

## Home return and recommendations

Home and Back now use one return function: prepare the underlying destination,
fade the detail and collapse navigation over 240ms, then remove the detail and
cancel its requests after the animation. Repeated clicks cannot launch competing
returns; search/disconnection invalidates pending completions. Clicking during
the entrance waits for its cover to land before returning. Button press feedback
does not inherit the navigation animation.

Home hides Watch What You Love and presents Discover New Music followed by Your
Daily Mixes first. Other shelves retain their order, and original items, IDs and
pagination are preserved. Three new tests cover presentation, heading matching,
and paging through the original data; the full Swift suite now has 49 tests.
All 49 pass and the release build succeeds. Native checks covered Home from
Discover Weekly, Back from a Metallica search detail, and Home from that same
search detail. The app is left on the reordered Home page without starting playback.

## Navigation motion follow-up

Back and Home remain mounted in a fixed 68pt toolbar slot. Home slides 40pt while
Back fades and shifts 8pt, using the cover's shared 240ms ease-in-out animation.
Entry starts in the same transaction as the cover flight, after its destination
has been measured. Back/Home return uses the same easing; clearing the cover
overlay no longer inserts or removes toolbar controls. Hidden Back is excluded
from hit testing, accessibility and focus. Reduce Motion skips the movement.

The 46 Swift tests and release build pass. Collection opening and returning Home
were checked in the native app. This changes toolbar motion in both directions;
the cover still animates on collection entry only.

## Screenshot annotation follow-up

1. Collection and song covers share the same 28pt left inset; row padding no longer
   adds an extra inset before the image.
2. The now-playing cover shares that inset and the playlist row's 42pt size.
3. The titlebar retains Back and Home without the breadcrumb separator or label.
4. The player places transport controls to the left of progress, with progress
   and system-volume sliders centered on the same horizontal line.
5. Search comes before Settings; the settings cog is the rightmost toolbar control.

The rebuilt native app was checked on Your Summer Rewind with The Real Slim Shady
in the player: cover edges and sizes match, both sliders share a horizontal line,
the titlebar has no breadcrumb text, and the cog opens Refresh/Reconnect.
Playback was exercised and left paused, with system volume unchanged. All 46 Swift
tests pass and the release build succeeds.

## UI/UX follow-up

Collection headers show the name aligned with the top of the cover, followed by
the description and Play. The type label and song count are omitted so loading
the count does not shift Play.

| Request | Change | Validation |
| --- | --- | --- |
| 1. Hover arrow | Collection hover badge uses `arrow.up.left.circle.fill` | Release build; symbol verified in source |
| 2. Cover transition | The clicked card's loaded image and viewport frame animate for 240ms into the 196pt top-left cover. Source browsing stays mounted for Back. Reduce Motion opens directly; navigation cancels the overlay; scrolling waits for the flight and resize updates its destination. The cover image persists beyond the flight and the final overlay handoff disables implicit animations. | Opening, post-transition scrolling and Back checked in the native app. The follow-up halves the former 480ms duration, moves the destination from right to left, and removes the unintended opacity fade triggered when flight state was cleared. |
| 3. Shorter songs section | First seven songs, centered Expand/Collapse, then Artists, Playlists and Albums | Native Metallica search and Expand/Collapse verified |
| 4. Automatic search | Native edits publish immediately; one 400ms model debounce owns requests. Every edit cancels and invalidates pending results/errors. Return submits immediately without duplication. | Native search without Return; seven deterministic search tests |
| 5. System volume | CoreAudio reads/listens to default output volume and mute, preserves balance, follows device changes, and writes on every slider edit. Unsupported hardware disables the slider. Engine gain is initialized to 100% so it does not multiply system attenuation. | Native slider to macOS Sound and Sound to native slider verified; original 43.75% restored. Seven injected volume tests cover notifications, mute, balance, routes, errors and cleanup. |
| 6. Larger song artwork | Search song covers increased from 42pt to 56pt; detail rows retain their existing size | Native search screenshot inspected |

All 46 Swift tests pass and the release app was rebuilt and ad-hoc signed in
`dist/Tops.app`. The Rust helper was not changed. Spotify Connect can still
independently change the helper's software gain after authentication; this
follow-up links native/macOS output volume, not remote Connect volume.

## Earlier review

The six comments on the first screenshot were applied to the SwiftUI app.
`ui-review-v2.html` contains fresh native screenshots for the next review.

| Comment | Change | Validation |
| --- | --- | --- |
| 1. Top-right search | Persistent native search field in the titlebar; Cmd-F focuses and selects it | Native screenshot verified right placement; live search accepted spaces while music kept playing |
| 2. Breadcrumb navigation | Home icon, chevron, and current section/collection name replace the app title | Home and collection headings verified in the native window |
| 3. Remove sidebar | Single full-width content area; Spotify options moved to the toolbar menu | Native screenshot has no sidebar |
| 4. Space toggles playback | Window-local Space shortcut, excluding text entry, focused controls, repeats, and modified keys | Live pause/resume; Space typed into search did not pause playback; three keyboard tests |
| 5. Align covers | Grid cells align at the top, with consistent title/subtitle line slots | Mixed title/description lengths have aligned cover edges |
| 6. Open collection details | Cards open cover, metadata, songs and durations; Back returns to the prior section; explicit Play starts the collection | On Repeat showed 24 tracks; Random Access Memories showed 13; opening either kept playback paused; Home/Back verified |

Playlist and album pages load 50 raw entries at a time and expose Show more when
more entries exist. Repeated tracks retain distinct row identities. Artist cards
show the top tracks returned by Spotify. A track-row click plays that individual
track; the collection Play button starts its full Spotify context. Empty or
unplayable collections have Play disabled. Spotify's DJ card returned zero tracks
in this test; dynamic DJ programming is not implemented.

Leaving a collection cancels its request and rejects late results. Failed page
loads retain already loaded tracks and can be retried. Four navigation tests and
six collection parser/request tests cover those boundaries and Spotify wrappers.
The full Swift suite passed 32 tests; the operation extractor's six Python tests
also passed. The Rust playback engine is unchanged by this UI work.
