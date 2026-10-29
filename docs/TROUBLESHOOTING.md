# Troubleshooting

Start with **Settings › Diagnostics**: it shows memory and CPU, the interaction state, the detected notch geometry, each feature's status, and a recent event log (in memory only, with paths redacted). For a headless check, run:

```bash
~/Applications/Nook.app/Contents/MacOS/Nook --self-test
```

## Nothing happens when I hover over the notch
- Check whether hover is paused (menu bar icon › *Resume Notch Hover*, or *Settings › General*).
- The activation area is the notch itself (185×32 pt on a 14-inch MacBook Pro). If it feels too small, widen it under *Settings › General › Activation area calibration*. The current rectangle is shown there.
- With the lid closed or the built-in display off, hover is disabled on purpose. Use ⌥⌘N or the menu bar.
- In a full-screen app, hover works only if *Available in full-screen apps* is on.
- ⌥⌘N doesn't respond: another app may own that shortcut (Diagnostics logs "Shortcut … is unavailable"). Pick another one in Settings.

## The panel closes while I'm using it
It stays open while you type, while a menu, alert or file panel is open, during Quick Look, and while you drag. If it still closes too soon, raise the **Close delay**, or pin it with 📌.

## Ollama / Assistant
| Symptom | Fix |
|---|---|
| "Ollama isn't running on this Mac" | Open the Ollama app, or run `ollama serve`, then **Retry**. Nook never starts Ollama itself except through the *Open Ollama* button. |
| "The model … isn't installed" | Choose an installed model from the menu, or install one yourself: `ollama pull qwen3:8b`. Nook never downloads models. |
| Endpoint rejected | Only loopback addresses are allowed (`http://127.0.0.1:11434`, `http://[::1]:11434`, `http://localhost:11434`). This is deliberate. |
| First reply is slow | The model loads on first use (a few seconds for qwen3:8b on Apple silicon). Use a longer *Keep model in memory* if you want faster follow-ups. |
| Memory is high | qwen3:8b uses about 6 GB while loaded. Click **Unload** in the Assistant header, or choose *Unload after each reply*. |
| Replies show reasoning or are slow | Turn off *Let thinking models reason* (the default is off). |

## Spotify / Music
| Symptom | Fix |
|---|---|
| "Spotify isn't running" | Open Spotify. Nook never launches it. |
| "Nook needs your permission" | Click **Connect to Spotify** and approve the macOS prompt. |
| "Nook isn't allowed to control Spotify" | Go to *System Settings › Privacy & Security › Automation › Nook* and enable Spotify, then click **Check Again**. |
| Permission keeps reappearing after reinstalling | Ad-hoc–signed builds get a new signature on every rebuild, and macOS ties the approval to it. Approve again, or remove the stale entry with `tccutil reset AppleEvents dev.local.nook` (this only affects Nook) and reconnect. Signing with a Developer ID (`NOOK_SIGN_IDENTITY`) avoids this. |
| No artwork | *Settings › Music › Load album artwork* is off, or the Mac is offline. Controls still work. |
| Progress jumps occasionally | Position is interpolated locally and re-synced every few seconds (adjustable). |

## Spotify search
| Symptom | Fix |
|---|---|
| "Catalogue search needs a one-time Spotify setup" | Expected without a Client ID. Use **Search in Spotify app**, or set it up in Settings › Music. |
| Dashboard says "This redirect URI is not secure" | Include the port: `http://127.0.0.1:43827/nook-callback` (Staging) or `http://127.0.0.1:43828/nook-callback` (Nook). The dashboard rejects port-less loopback URIs, `localhost` and custom schemes. |
| Sign-in fails with "INVALID_CLIENT: Invalid redirect URI" | The registered URI must match exactly, including the port and `/nook-callback`. Copy it from Settings › Music. |
| "Port 43827 … is in use by another app" | Another program is using that port. Quit it and sign in again (the port is only needed during sign-in). |
| "This build can't receive Spotify's sign-in redirect" | The build was made without the loopback listener. Rebuild with `NOOK_ALLOW_LOOPBACK_SIGNIN=1 scripts/build-app.sh` (or use `scripts/stage.sh`). |
| Search fails with "403 … Insufficient client scope" | Fixed in current builds (they no longer use `market=from_token`). If it persists, sign out and sign in again in Settings › Music. |
| After rebuilding Nook, macOS asks to allow access to "Nook — Spotify sign-in" | Ad-hoc–signed rebuilds are a new app identity to the Keychain. Click **Always Allow**, or sign in again. |
| Search works for you but not for someone else | Development-mode apps allow at most 5 users, and the owner needs Premium; add users under *User Management* in the dashboard. |
| Sign-in works, but search returns 403 | Spotify limits apps in development mode to users listed in the dashboard (User Management). Add your account there. Spotify's developer-mode rules change from time to time; check the dashboard. |
| "Sign-in expired" | Sign in again. Nook refreshes tokens automatically, but a revoked or very old token needs a new sign-in. |
| A result plays but Next does nothing | Results play within their album. A track that Spotify reports without an album plays on its own. |
| macOS asks for Keychain access after rebuilding | Ad-hoc–signed builds change signature on each rebuild. Allow access, or sign out and in again. |

## Drag and drop
- **Dropping onto the notch does nothing**: drop while the panel shows "Release to add to Shelf". Some apps offer only formats Nook doesn't store (e.g. app-private data). In that case, copy and paste with the clipboard button, or save the file first and drag it from Finder.
- **Promised files** (Mail attachments, Photos, some browser images): the source app writes the file on demand. If it fails, the banner shows the app's error. A file received just before Nook quit is imported on the next launch.
- **Dragged out, but the item didn't disappear**: the destination reported that it didn't accept the drop (or you dropped back onto Nook), so the item was kept on purpose. Use *Save a Copy As…* or *Move To…* for a guaranteed transfer.
- **Dragged out, the item disappeared, but the destination doesn't have it**: open *⋯ › Recently Removed* and restore it. Nook keeps the file for the retention period because some apps confirm a drop before they finish reading it.
- **Can't drag a Shelf item back onto the Shelf**: intentional (no accidental duplicates).

## Shelf data and recovery
- The storage location is shown in *Settings › Shelf* (normally `~/Library/Containers/dev.local.nook/Data/Library/Application Support/Nook/Shelf`). Each item is a folder in `items/` holding the original-named file plus `item.json`.
- A **"…recovered…" / "…missing…" banner** appears after an unexpected shutdown or a change made outside Nook. Recovered items are safe to use. Missing items had their stored file deleted outside Nook; remove the entry once you've checked.
- **"index was damaged and rebuilt"**: the old index was saved as `shelf-index.corrupt-<time>.json` next to the new one.
- Time Machine and other backups include the container only if they back up `~/Library/Containers`. Don't rely on the Shelf as long-term storage.

## Login item
- *Settings › General* shows the status. **"Waiting for your approval"** means: open *System Settings › General › Login Items* and allow Nook.
- The login item is registered only from an installed copy (`~/Applications` or `/Applications`), never from the build folder.
- After moving or reinstalling the app, toggle *Open Nook at login* off and on.

## Quitting and resetting
- Quit from the menu bar (*Quit Nook*). Nook also treats `kill -TERM <pid>` as a normal Quit.
- To reset settings only: quit Nook and delete `~/Library/Containers/dev.local.nook/Data/Library/Preferences/dev.local.nook.plist`. Shelf items aren't affected.
