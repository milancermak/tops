# Memory profiling

September 27, 2026, Apple Silicon, macOS 15.7.4. **Combined physical footprint
during playback fell from 104.3 to 71.06 MiB, about 32%, in a single before/after
run of the same feed/search/playback workflow.** The scrolled feed measured
72.98 MiB and paused playback 71.02 MiB. These are spot checks, not a repeatable
benchmark or a comparison with Spotify.app.

The raw observations are in [memory-profile.jsonl](memory-profile.jsonl).
`tools/profile_memory.py` records each app/helper PID, current `vmmap` physical
footprint, `ps` RSS and a CPU sample. It stores totals rather than heap contents,
credentials or authenticated API responses.

## Main comparison

All figures below are MiB of current physical footprint, summing the app and
its own Rust helper.

| State | Before | Optimized |
| --- | ---: | ---: |
| Feed loaded and scrolled | 90.24 | 72.98 |
| Playing | 104.3 | 71.06 |
| Paused after playback | 104.3 | 71.02 |

The final `allocator-*` samples split as follows: feed 66.9 MiB UI and 6.08 MiB
helper; playing 63.7 and 7.36 MiB; paused 63.6 and 7.42 MiB. The playback sample
was recorded at 19:01:39 and the pause sample at 19:03:04. The UI showed advancing
Etta James playback, then a Play button with position 1:51 after approximately
111 seconds of continuous playback. No human listening confirmation was recorded.

The same build then sought backward from 1:51 to 1:31 and resumed; progress
advanced through 2:22 and 2:48 before pausing at 3:12. The final Play button and
10% volume were confirmed. A further paused sample measured **71.01 MiB**
(63.7 MiB UI and 7.31 MiB helper), recorded as `allocator-paused-after-resume`.
Feed, search and these playback controls were verified on the final build.

The app retains `MallocSpaceEfficient=1` in its bundle launch environment.
Launch-only UI samples were 25.4 MiB for this build, 28.7 MiB for the preceding
candidate and 40.5 MiB for the baseline. These separate launches may differ in
framework/cache warm-up; they do not isolate the allocator setting's contribution.

## Intermediate experiments

The first custom image-loading pass did not reduce memory: playback measured
106.0 MiB, and the scrolled feed's UI alone reached 90.3 MiB versus the baseline's
82.8 MiB. Reducing the thumbnail cache and requesting idle allocator relief gave
a 94.79 MiB scrolled-feed sample. The raw labels `final-feed-scrolled` and
`final-feed-settled` refer to this intermediate second pass, not the final
candidate. The viewport pass then measured 85.95 MiB (79.1 MiB UI and 6.85 MiB
helper) before enabling the allocator launch setting. All intermediate samples
remain in the JSONL file. The older 83.1 MiB long-paused sample has a different
settling interval and cannot replace the immediate-pause baseline.

In a separate isolated helper probe, physical footprint fell from **24.1 to
11.5 MiB** across an idle allocator-relief call, while its `released_bytes`
return value was zero. This observation comes from `diagnose_engine_memory.py`,
not the app samples above. It shows that the API's return value alone is not a
reliable before/after footprint measurement; it does not establish how much of
the change was caused by that call rather than settling or OS reclamation.

## Changes retained

- Downsample artwork with ImageIO at the displayed Retina size, bound the
  thumbnail cache, share simultaneous requests and cancel unused downloads.
  An idle task asks macOS to release unused allocator pages after decode bursts.
- Keep per-second playback position and unchanged snapshots from invalidating
  the entire recommendation/search view or rebuilding its item arrays.
- Limit the helper's Tokio runtimes to two workers each and release unused
  allocator pages on pause transitions. An explicit idle-only command also
  permits isolated allocator measurements.
- Load artwork only for the visible viewport and release offscreen images.
- Configure `MallocSpaceEfficient=1` for Tops' launch environment, without
  changing the user's global environment. Apple's allocator source describes a
  space-versus-time tradeoff: more aggressive page reclamation and disabling
  the large-allocation reuse cache. [Apple libmalloc implementation](https://github.com/apple-oss-distributions/libmalloc/blob/libmalloc-646.0.13/src/malloc.c).

Audio remains configured at **320 kbit/s**, with normalization enabled and the
existing CoreAudio path. Decoder and playback buffers have not been reduced.
The personalized feed and search continue using the same API and data models;
this work does not replace recommendations with a smaller substitute feed.

## Reading and repeating the measurements

RSS and physical footprint are different measures. RSS includes resident clean
mapped code and frameworks, as well as other resident pages; it is not all
application-owned heap that can be removed. `vmmap -summary` categories such as
MALLOC, ImageIO, CoreAnimation and mapped code help locate growth. The profiler
records current physical footprint separately from RSS; neither virtual address
space nor a process's lifetime peak should be used as current memory usage.

For a comparison, use fresh release builds with the same window size/display
scale, account, feed scroll position, loaded artwork, track and playback state.
Record launch, loaded/scrolled feed, settled playback and settled pause. Keep
settling intervals consistent, repeat runs, and compare app plus helper. One
CPU percentage sample is not a sustained CPU or responsiveness benchmark.

```sh
python3 tools/profile_memory.py candidate-playing --output docs/memory-profile.jsonl
```

The current records are exploratory spot checks, not a randomized benchmark.
Repeat runs, long-session behavior and sustained CPU/latency measurements remain
outstanding. The offline suite passes 19 Swift, five Rust and six Python tests;
this does not establish long-session stability or audio quality.
