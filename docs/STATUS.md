# Status

Nook 1.0 is in daily use on a 14-inch MacBook Pro running macOS 26. This page lists what is verified, what still needs testing, and what's next.

Legend: ✅ implemented and covered by automated tests, the sandboxed self-test or measurement · 🟡 implemented and used, not yet covered by automation (see the manual checklist in [TESTING.md](TESTING.md)) · ⛔ not implemented

## Shelf
| Capability | Status |
|---|---|
| Transactional import (validate → stage → copy under file coordination → verify size + SHA-256 → sidecar → atomic exclusive rename → index) | ✅ |
| Rollback on missing source, permission error, disk full, corrupt copy or cancellation; source never modified | ✅ |
| Crash recovery: incomplete imports, lost index entries, corrupt index, orphan files, missing content, pending promises | ✅ |
| Save a Copy As / Move To with verify-then-remove, Keep Both / Replace (confirmed) / Cancel | ✅ store logic · 🟡 panels and alerts |
| Recoverable removal (Remove, Clear, cleanup, drag-out → Recently Removed; retention purge) | ✅ store logic · 🟡 UI |
| Drag in from Finder and apps (file URLs, file promises, text/URLs, image data) | 🟡 |
| Drag out with `NSDraggingSession`, copy-only, hidden only on reported acceptance | ✅ resolution logic · 🟡 real drag sessions |
| Scale: 500 items | ✅ |

## Notch
| Capability | Status |
|---|---|
| Notch geometry from public `NSScreen` APIs, calibration, fallback strip | ✅ |
| Interaction state machine (8 states, anti-flicker, pin, interaction lock, drag states, suspend) | ✅ |
| Non-activating panel, tracking-area hover, spring and reduced-motion animations, outside-click close, Esc | 🟡 |
| Global shortcut ⌥⌘N (Carbon, no Accessibility permission) | ✅ |
| Launch at login via `SMAppService.mainApp` (installed copies only) | ✅ |
| Now-playing peek on the closed notch (Core Animation, ~0 % CPU while animating) | ✅ measured · 🟡 visual |

## Assistant
| Capability | Status |
|---|---|
| Loopback-only endpoints; cloud models filtered and refused; never downloads models | ✅ |
| Streaming, stop/cancel, thinking channel, stats, unload | ✅ (live test against `qwen3:8b`) |
| Markdown with code copy, quick actions, prompt scratchpad, history retention, save to Shelf | ✅ logic · 🟡 UI |

## Music
| Capability | Status |
|---|---|
| Spotify detection (installed / running / permission); never launches Spotify | ✅ |
| AppleScript controls, seek, volume, `PlaybackStateChanged` events | ✅ |
| Artwork from Spotify's CDN only (HTTPS allow-list, 6-item cache) | ✅ |
| Catalogue search with PKCE sign-in; results play within their album via the Web API | ✅ |

## Known limitations
- **No signed release yet.** Builds are ad-hoc signed, so you build from source. macOS may ask for Spotify and Keychain permission again after each rebuild. A Developer ID build fixes that.
- **Drag-out confirmation** relies on what the destination app reports. Nook hides an item only on reported acceptance and keeps its file for the retention period, but it can't prove a third-party app read the file.
- **Spotify catalogue search** needs your own Spotify developer app, and Spotify requires that app's owner to have Premium.
- **External displays**: hover works only on the built-in display, by design. The shortcut and menu bar work everywhere.
- **Macs without a notch** get a nearly transparent strip at the top centre of the screen. This is less tested.
- **No UI tests**: UI behaviour is covered by the manual checklist in [TESTING.md](TESTING.md).

## Ideas for what's next
- Signed and notarized releases with a Homebrew cask
- Apple Music support alongside Spotify
- UI test coverage for drag and drop and the panel
- More Assistant quick actions, and custom ones

Want to help with one of these? See [CONTRIBUTING.md](../CONTRIBUTING.md).
