# Remote appearance

The SDK reads `data.appearance` from `GET /consent/config?code_config=...` with
its existing integration header. Normal form loading shares the content response;
there is no additional appearance request. Validated schema 1 tokens are persisted
per base URL, API path and integration key without TTL. Each successful network
config response automatically applies and persists a changed valid appearance.
An unchanged profile reuses prepared fonts and does not rewrite the appearance
cache. Offline/missing/invalid appearance keeps the last valid profile, or defaults
when no good cache exists. A later valid config can recover within the same session.
Cached consent content never downgrades a newer appearance cache. Standalone
`getAppearance()` on a cache miss fetches config; normal form loading needs no
additional request or customer controls.
The native form model applies appearance to SwiftUI and the UIKit hosting controller.
An explicitly supplied `ConsentTheme` takes precedence over remote colors/shapes.

```swift
let appearance = await cmp.getAppearance()
```

Refresh/clear remain optional integrator APIs and are not customer-facing buttons.
Open forms keep their snapshot until loaded again. Offline first loads use SDK
defaults; the next successful config response can recover in the same session. Font assets use public HTTPS URLs and
SHA-256, accept at most four files of 4 MB each, and persist beside the profile.
Missing/broken fonts fall back to system fonts without network retries. Explicit
refresh can retry font assets. App-registered fonts use their PostScript name.
Content-addressed font files may be shared by profiles and remain after clearing
one profile; clearing app data removes all. App backup/restore policy controls
whether an installation restores old profiles.

Backend contract and portal are described in Android's REMOTE_APPEARANCE.md.
Windows validation checks syntax only; run `swift test` and the example on a Mac
before publishing iOS support.
