# librespot-core OAuth provider patch

`librespot-core/` is the core crate from librespot upstream commit
`939dc5ee9d833e1980f9495241219d9d4868a061` (MIT; license retained).
All other librespot crates still use that exact upstream revision.

The local patch adds `login5::TokenProvider` and
`Login5Manager::set_token_provider`. When supplied, native HTTP and dealer token
requests use the application's provider. Provider errors propagate directly;
the default upstream Login5 path is unchanged for callers without a provider.
The callback is awaited outside the component mutex and must not capture a
strong Session reference. Tops supplies its existing desktop OAuth grant and
serializes refresh with browsing through one shared authorization store.

Why: on September 29, 2026, Login5 returned HTTP 503 after successful access-point
authentication, including with freshly obtained credentials. Upstream issue:
https://github.com/librespot-org/librespot/issues/1771
Tops' desktop OAuth token was independently accepted by Spotify's native dealer
(HTTP 101) and native track metadata (HTTP 200) during this incident.

Packaging changes in this copy: workspace-inherited package fields are made
explicit, OAuth/protocol dependencies point to the same pinned upstream Git
revision, and the build script preserves the original short revision in runtime
identity. Source other than `src/login5.rs` is unchanged. No credentials are
embedded here. Keep this small API patch explicit when updating librespot.
