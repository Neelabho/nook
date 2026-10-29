# Architecture

## Platform notes

| Area | Decision |
|---|---|
| OS | Deployment target is macOS 15. Liquid Glass APIs are used on macOS 26+ behind `#available(macOS 26)`, with material and opaque fallbacks. |
| Toolchain | A plain Swift package: Xcode **or** just the Command Line Tools. The `.app` bundle is assembled and signed by `scripts/build-app.sh`; Swift Testing runs through `scripts/test.sh`, which adds the search paths the Command Line Tools need. |
| Signing | Ad-hoc by default. Pass `NOOK_SIGN_IDENTITY` to sign with a Developer ID. |
| Display | The notch rectangle is derived from public `NSScreen` APIs (`safeAreaInsets`, `auxiliaryTopLeftArea`/`RightArea`); nothing is hard-coded. On a 14" MacBook Pro this gives 185×32 pt. |
| Ollama | Talked to over its local HTTP API only. Nook prefers `qwen3:8b` when installed, checks for the server on demand, and never downloads models. |
| Spotify | The desktop app's AppleScript dictionary plus its `com.spotify.client.PlaybackStateChanged` notification cover playback. The Web API is used only for the optional catalogue search. |

## Modules

```
Sources/NookCore            pure logic, no AppKit, fully unit-tested
  Shelf/                    ShelfStore (actor), ShelfLayout, FileSafety, ContentSniffer, policies
  Interaction/              NotchStateMachine (pure reducer), NotchGeometry
  Assistant/                OllamaClient + transport, ThinkTagFilter, MarkdownParser, AssistantStore
  Music/                    SpotifyStatusParser, PlaybackClock, MusicCapabilities, ArtworkURLPolicy
  Settings/                 NookSettings (validated, tolerant decoding), HotKeySpec
  Diagnostics/              Redactor, DiagnosticsLog (bounded, in memory)

Sources/Nook                the app
  App/AppLifecycle.swift    AppEnvironment (wiring), AppDelegate, HotKeyManager (Carbon),
                            LoginItemController (SMAppService), StatusItemController (menu bar)
  App/SelfTest.swift        --self-test (headless checks inside the sandbox)
  Notch/                    NotchPanel + NookRootView (tracking area, drag destination),
                            WindowCoordinator (drives the state machine), NookRootContent (SwiftUI)
  Design/                   LiquidGlassDesignSystem: NotchShape, NotchSurface, controls
  Shelf/                    ShelfController, ShelfView/ShelfTile, ShelfDragSource (NSDraggingSource),
                            QuickLookCoordinator, ThumbnailProvider
  Music/                    SpotifyService + AppleScriptRunner, MusicView, VinylView (Core Animation)
  Assistant/                AssistantModel, AssistantView, MarkdownView
  Settings/                 SettingsService, DiagnosticsService, SettingsWindow
```

The Shelf has no dependency on the Assistant or Music features.

## Shelf data-safety model

Storage root is `~/Library/Containers/dev.local.nook/Data/Library/Application Support/Nook/Shelf/`:

```
shelf-index.json     ordered index (a cache — rebuildable)
items/<uuid>/        one item per folder: item.json (sidecar metadata) + content under its sanitized original name
staging/<txn>/       imports in progress (never visible)
trash/<uuid>/        deletions in progress
incoming/<txn>/      files delivered by drag promises, not yet imported
```

**Import transaction**
1. Validate the source: it must exist and be readable, be a regular file or folder (symlinks resolved), and not already be inside the Shelf.
2. Check free space; at least 64 MB must remain after the copy.
3. Copy into `staging/<txn>/` under `NSFileCoordinator` read coordination, using `FileManager.copyItem` (`copyfile`, APFS clone when possible; files are streamed, never loaded into memory).
4. Verify: byte and file counts must match. Files up to 2 GB must also match by **SHA-256** (streaming). Larger files are verified by size.
5. Sniff the content type from magic bytes. Extensions aren't trusted; a mismatch is flagged in the UI.
6. Write the sidecar `item.json` into the staging folder.
7. **Commit**: `renamex_np(RENAME_EXCL)` renames `staging/<txn>` to `items/<uuid>` in a single atomic step that never overwrites.
8. Update the index (atomic write). If that write fails, the item is still safe: the next launch rebuilds the index entry from the sidecar.

Any failure removes `staging/<txn>`. The source is only ever read. A crash at any point leaves either nothing visible or a fully committed item.

**Launch reconciliation** (`ShelfStore.open`)
- Removes leftover staging folders, which are uncommitted.
- Finishes deletions left in `trash/`.
- If the index is corrupt, sets it aside (`shelf-index.corrupt-<ts>.json`) and rebuilds it from the sidecars.
- Recovers item folders that are missing from the index; this works even without a sidecar, from the content alone.
- Marks index entries whose content is missing as **missing** rather than dropping them.
- Leaves unrecognized files untouched and reports them.
- Imports files left in `incoming/`.

The result is shown as a banner in the Shelf and in Settings › Shelf › Recovery.

**Export (Save As / Move To)**
- Destinations inside the Shelf root are rejected.
- Name conflicts follow the requested policy. **Fail** throws. **Keep Both** picks a Finder-style "name 2.ext". **Replace** happens only after explicit confirmation: NSSavePanel's own prompt, or Nook's two-step alert.
- A **same-volume move without a conflict** is a single atomic rename.
- Otherwise the item is copied to a temporary sibling on the destination volume. The copy is verified (size and file count, plus SHA-256 against the import hash), then placed with an exclusive rename (or `replaceItemAt` for a confirmed Replace) and verified again. **Only then** is the Shelf copy removed (Move) or kept (Copy).
- Items being transferred are **busy**, so they can't be removed, cleared, cleaned up or exported twice.

**Removal is always recoverable first.** Remove, Clear Shelf, confirmed cleanup and confirmed drag-outs all mark items *recently removed*. The content stays on disk, which matters for destinations that read a dropped file lazily. Permanent deletion happens only after the retention period (default 7 days, configurable) or through an explicit "Delete All Now…".

**Drag-out**
- Uses `NSDraggingSession` directly. SwiftUI's `onDrag` can't report whether the destination accepted the drop.
- The pasteboard carries the real stored file URL; text items carry text (⌥ drags a `.txt` file instead).
- Only `.copy` is offered (`sourceOperationMask`), so destinations never move or delete Nook's file.
- `draggingSession(_:endedAt:operation:)` reports the operation the destination performed. `[]` means it was cancelled or rejected, so the item stays. Copy or generic means accepted, and the after-drag preference applies (hide recoverably, or keep).
- **Limitation:** AppKit reports what the destination *claims*. Some apps return `.copy` before they read the file, which is why "accepted" only hides the item and never deletes the file. Finder copies synchronously.

**Drag-in**: file URLs come first (Finder and most apps), then `NSFilePromiseReceiver` (Mail attachments, Photos, browsers; received into `incoming/` and then imported), then text and URLs, then raw PNG/TIFF image data.

## Notch window and interaction

- **Panel**: one borderless `NSPanel` with `.nonactivatingPanel`, at `.statusBar` level. Collection behavior is `canJoinAllSpaces, stationary, ignoresCycle`, plus `fullScreenAuxiliary` if enabled. Hovering never activates Nook or takes keyboard focus. The panel becomes key only when you click a text field or open it with the keyboard. After a collapse, key status goes back to the frontmost app.
- **Closed state**: the panel is exactly the activation rectangle, which defaults to the notch (185×32), and is drawn solid black. That makes it invisible against the camera housing, and nothing permanent sits on the menu bar. On a display without a notch, the strip is nearly transparent. Nook appears only on the built-in display. With the lid closed, hover is off, and the shortcut or menu opens the panel on the main display.
- **Expanded state**: the panel frame grows first, then SwiftUI animates `NotchShape` from the closed size to 660×300 (or 820×580 in large mode) with a spring. Collapse runs in reverse; Reduce Motion switches to a short fade.
- **Pointer**: an `NSTrackingArea` on the panel's root view, so there is no global mouse polling. `NSEvent.mouseLocation` is read once when a timer fires, to avoid collapsing while the pointer is inside. A global mouse-down monitor, which needs no permission, is installed **only while the panel is open**, so clicking elsewhere closes it.
- **State machine** (`NotchStateMachine`, a pure reducer): states are `idle`, `hovering`, `expanding`, `expanded`, `dragTargetActive`, `draggingFromShelf`, `collapsing` and `suspended`. Context flags are `hoverEnabled`, `pinned`, `interactionLock` (typing, a menu, sheet, alert or Quick Look open, or opened by keyboard), and `pointerInside`. The reducer returns effects (start or cancel timers, expand, collapse, show drop target) that the coordinator performs. Late timer callbacks are ignored in the wrong state, which prevents flicker.
- **System events**: sleep or screens-sleep → `suspend`; wake → recompute geometry and `resume`; screen-parameter changes → recompute geometry; Space change → close unless pinned.
- **Keyboard**: a Carbon `RegisterEventHotKey` global shortcut (no Accessibility permission). Inside the panel: Esc closes, ⌘1–3 switch tabs, and the Shelf uses arrows, Space, Delete, ⌘V and ⌘-click.

## Assistant

- `OllamaClient` accepts **only loopback endpoints** (`127.0.0.1`, `::1`, `localhost`) with no credentials, path or query. Validation runs at input and again when settings load, and models tagged as cloud (`remote_host`, `*-cloud`) are filtered out and refused. The URLSession is ephemeral, with no cookies, cache or proxies.
- Nothing happens until the Assistant tab opens. That triggers one `/api/version` + `/api/tags` check, throttled to 30 s, plus `/api/ps` for memory. There is no preloading and no polling.
- Chat streams NDJSON from `/api/chat`, with `think` set only for thinking-capable models (from `/api/show`), `num_ctx` / `num_predict` limits, and a `keep_alive` setting. UI updates are batched at about 20 Hz. Stop cancels the task, which cancels the HTTP request. Inline `<think>` tags are split even when they arrive across chunks.
- Context is bounded: a system prompt plus the last N messages (default 20). The conversation is saved as JSON in Application Support, or kept in memory only, depending on the setting.
- User text for quick actions is wrapped in `<text>…</text>` delimiters, so it's treated as material rather than instructions.

## Music

- Uses the AppleScript dictionary on a dedicated serial queue (`NSAppleScript` isn't re-entrant), so the main thread never blocks. Every script is guarded by `if application id "com.spotify.client" is running`, so **Nook never launches Spotify**. Scripts are constant strings; only formatted numbers are interpolated.
- Permission is checked with `AEDeterminePermissionToAutomateTarget`. Nook prompts only when you click **Connect**.
- Updates are event-driven through `com.spotify.client.PlaybackStateChanged`: the notification payload updates state cheaply, and a full AppleScript refresh runs only while the Music view is visible. While it's visible and playing, the position is re-synced every N seconds (default 5) and interpolated locally between syncs (`PlaybackClock`). The progress `TimelineView` ticks at 1 Hz only while playing.
- Artwork comes over HTTPS only from `*.scdn.co` / `*.spotifycdn.com`. It is fetched once per track into a 6-entry in-memory cache, and fetching can be disabled.
- The vinyl is drawn once into a bitmap and spun by a `CABasicAnimation` in the render server, at 33⅓ rpm (1.8 s per revolution). Pausing freezes the layer in place (`speed = 0`), and the animation is removed when the view leaves the screen.
- **Not used:** the private MediaRemote framework. The Spotify Web API is used only by the optional catalogue search (below).

## Dark Liquid Glass design system

One shared surface treatment and one button style (Design/DarkGlass.swift), used by every section.

- **`darkGlass(in:tint:highlighted:interactive:)`:** for cards, fields, tiles, capsules and bubbles.
- **`glassField(focused:)`:** for text inputs.
- **`GlassDropletButtonStyle`:** circular 3D glass buttons.
- **Existing names kept:** `GlassIconButton`, `PillButtonStyle`, `nookGlass` and `sectionCard` now sit on these, so Music, AI, Shelf, search and the tab bar share them without duplicated styling. The Settings window uses the dark appearance.
- **Rendering modes (`GlassAppearance`, unit-tested):**

| Mode | When | What it is |
|---|---|---|
| `liquidGlass` | macOS 26+ | System Liquid Glass (`glassEffect`) with a charcoal tint. The window server samples and lenses **Nook's own content behind the glass**: genuine refraction by the system, not a gradient. It can't refract the desktop behind Nook's window, and Nook won't screen-capture to imitate that. |
| `material` | macOS < 26 | Within-window blur and tint. Translucent, no refraction. |
| `opaque` | Reduce Transparency | Solid charcoal. |

- **Droplet decorations:** a specular cap, an inner shade along the lower edge, a faint rose/violet caustic (Play is strongest), a delicate rim and a floating shadow. They're decorative overlays with `allowsHitTesting(false)`, and hits are limited to each circle.
- **States:** hover brightens and scales to 1.04; pressed scales to 0.94 and deepens the shade; focus shows an accent ring.
- **Accessibility:** Increase Contrast strengthens rims and removes the glow; Reduce Motion removes scale and spring animations.
- **Text colour:** text inside glass has explicit colours, so the glass's adaptive vibrancy can't make it unreadable (a dock title disappeared this way earlier).
- **Cost:** glass is static and renders only on change. Groups of nearby glass shapes (the playback droplets, the Shelf row) sit in a `GlassEffectContainer`.

## Music panel

- **Layout:** artwork with the original vinyl → title, then "artist — album" (shown once) → progress slider with elapsed/remaining → three separate glass droplets (previous 40 pt, play/pause 52 pt, next 40 pt). The **only** top-right element is an understated magnifying glass.
- **Removed:** the heading, the dock/pill, the second track bar and the volume control.
- **Backdrop:** the album artwork, heavily blurred and clipped to the music content, never over the tab header.
- **Vinyl:** the existing `VinylView` (bitmap plus a Core Animation spin in the render server).
  - It spins only while Spotify reports *playing* (and Reduce Motion is off), and pauses in place via layer timing.
  - A track change swaps the label artwork without restarting the animation.
  - The angle is now remembered when the panel closes (`VinylRotation`, unit-tested). Reopening continues from where it was, or as if it had kept turning if Spotify kept playing.
- **Search:** opens as a dark-glass overlay, with the field focused after it's installed. Esc closes and returns to the clean layout.

## Spotify search

- **Why the Web API:** Spotify's AppleScript has **no search**. In-Nook catalogue results come from the official Web API: `GET /v1/search?type=track,artist,album&limit=6&market=<Mac region>`.
- **Market:** `market=from_token` returns **403 "Insufficient client scope"** without the `user-read-private` scope. To keep **zero scopes**, Nook sends the Mac's region (e.g. `IN`), or no market if the region isn't a 2-letter country code.
- **Development-mode rules (current):**
  - `limit` max 10 and default 5 per type (February 2026).
  - The app **owner needs Spotify Premium**.
  - **At most 5 users** per Client ID.
  - Quota shared per developer account; a 429 with `QUOTA_EXCEEDED` is reported distinctly.
  - `GET /artists/{id}/top-tracks` was removed, so artist results can't drill into a track list; playing an artist plays it as a context.
- **Authentication:** Authorization Code with PKCE, with no client secret. The only scope is `user-modify-playback-state` for starting a search result in its album; search itself needs none.
  - **Why a listener:** Spotify accepts only **HTTPS or loopback-IP redirect URIs**; custom schemes and `localhost` are rejected. So sign-in uses the RFC 8252 loopback pattern.
  - **Flow:** register `http://127.0.0.1:43827/nook-callback` (Staging) or `…:43828/…` (Nook). Spotify's docs allow a port-less loopback URI, but the dashboard rejects it as "not secure", so the port is fixed and explicit. At sign-in, Nook binds an `NWListener` to 127.0.0.1 on that port with `acceptLocalOnly`, and opens Spotify's authorize page in the default browser. If another app holds the port, Nook says so. It accepts only `GET /nook-callback` with the matching `state` and answers other requests with 404. The listener closes after success, failure or 5 minutes.
  - **Entitlement:** this needs the sandbox `network.server` entitlement.
    - **Opt-in:** builds include it only with `NOOK_ALLOW_LOOPBACK_SIGNIN=1` (`scripts/stage.sh` sets it). The listener binds to 127.0.0.1 only and exists only while a sign-in is in progress.
    - **Without the flag:** builds don't include it; Sign In there explains why it can't proceed.
    - **Receiver:** `LoopbackRedirectReceiver` handles the listener.
  - **Tokens:** stored in the Keychain per bundle ID, so staging and production are separate.
- **Without setup:** a clearly labelled fallback opens Spotify's own search (`spotify:search:`). Those results appear in Spotify, not Nook.
- **Results:** Songs, Artists and Albums, with artwork from the shared bounded cache.
  - Debounced at 350 ms; stale responses are discarded; loading, empty, error and retry states.
  - Playback happens only on ▶ or Return on a highlighted row.
- **Playback:** the Web API is primary, via `SearchPlaybackPlan` (unit-tested).
  - **Requests:** `PUT /v1/me/player/play` with `context_uri` = the album (songs, plus `offset.uri` = the song), album or artist.
  - **Why the Web API:** it plays **without bringing Spotify to the front**. AppleScript `play track` makes Spotify frontmost; verified by experiment, with Spotify's active state and the frontmost app observed. It also sets a real context, so a finished song continues through its album instead of looping with Repeat on.
  - **No active device (404):** Nook sends a plain AppleScript `play` (resume), which makes this Mac the active device without bringing Spotify forward (verified), then retries once.
  - **If the Web API can't be used** (scope missing, Premium, other errors): AppleScript `play track` plays the exact song, focus is handed back to the previously frontmost app, and the search panel explains the limitation.
  - **Never sent:** a device ID, repeat or shuffle.
  - **Logging:** each step's outcome goes to the diagnostics log (no tokens).
- **Granted scopes are tracked** with the token, and Settings offers **Sign In Again** if the scope is missing.

## Sandbox and entitlements

The app is sandboxed with the following entitlements:
- `network.client`: loopback Ollama and artwork.
- `files.user-selected.read-write`: Save/Move/Add panels.
- `automation.apple-events` plus a temporary exception for `com.spotify.client` only.
- `network.server` (**only** in builds made with `NOOK_ALLOW_LOOPBACK_SIGNIN=1`): the short-lived 127.0.0.1 listener for Spotify sign-in.

Nook does not request Accessibility, Screen Recording or Full Disk Access. Default builds open no listening sockets. Dropped files reach the sandbox through the drag pasteboard's implicit access grant. Quick Look and thumbnails use system services. The hardened runtime is enabled.

**Ad-hoc signing caveat:** macOS ties the Spotify Automation approval to the code signature. Each ad-hoc rebuild has a new signature, so macOS may ask again (or show a stale entry) after you reinstall a new build. With a Developer ID identity (`NOOK_SIGN_IDENTITY=…`), the approval persists.

## Version-dependent decisions

- Liquid Glass (`glassEffect`) is used for tab and chip chrome only on macOS 26+. Older systems get an equivalent translucent fill. The main surface uses a behind-window `NSVisualEffectView` with a black gradient on every version, so text contrast is predictable and the top edge matches the hardware notch exactly.
- `NSScreen.auxiliaryTopLeftArea/RightArea` and `safeAreaInsets` exist since macOS 12. Without them, Nook uses the fallback strip and the calibration sliders.
- `@concurrent` (Swift 6.2+) keeps file copying off the `ShelfStore` actor so several imports run in parallel.
