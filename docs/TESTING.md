# Testing

## How to run

```bash
scripts/test.sh                                        # everything except live services
NOOK_LIVE_OLLAMA=1 scripts/test.sh --filter LiveOllama # real Ollama (needs `ollama serve` + qwen3:8b)
build/Nook.app/Contents/MacOS/Nook --self-test         # headless checks inside the signed, sandboxed app
scripts/measure.sh 60 5                                # sample a running Nook's CPU / wakeups / memory
```

Every test uses a fresh temporary directory and synthetic files. Nothing touches your documents or the production Shelf. Test and staging builds use the separate bundle id `dev.local.nook.staging`, which gives them their own sandbox container.

## Automated suites

`scripts/test.sh` runs the whole NookCore suite in a few seconds; no network, Ollama or Spotify needed.

| Suite | What it covers |
|---|---|
| Shelf import | one PDF, 6 concurrent PNGs, MP3 type detection, a content/extension mismatch flag, a 96 MB file with SHA-256 verification, identical names with different content, duplicate skip vs keep, Unicode text, oversized and empty text, unusual filename characters (`Résumé – … 🎉 ;$(rm -rf) \`x\``), a read-only source (stays read-only; the Shelf copy is still removable), a missing source, an unreadable source (chmod 000), **disk full mid-copy** (partial file cleaned up, source unchanged), a low-free-space pre-check, **corrupted copy rejected by verification**, folders, refusing to re-import its own files, cancelled imports |
| Shelf persistence & recovery | persistence across reopen; **interrupted import** cleaned up; committed item missing from the index recovered; **corrupt index** set aside and rebuilt; missing content flagged (not dropped); orphan file without a sidecar recovered; unknown files left alone; pending promise files imported on launch; recently-removed retention with an injected clock; busy items protected from remove and clear |
| Shelf export | copy keeps the item; move removes it only after verification; **conflict = fail never overwrites** and leaves no temp files; Keep Both → "a 3.pdf"; Replace touches only the target; **failed export into a read-only folder rolls back** and keeps the item; export into the Shelf's own storage rejected; missing content fails safely; text → `.txt`; folder trees; a busy item can't be exported twice |
| Filename safety / sniffing / policies | path traversal (`../../etc/passwd`), separators, control characters, `.`/`..`, 255-byte truncation keeping the extension, numbered variants, containment, **`renamex_np(RENAME_EXCL)` never overwrites**, streaming hash; magic-byte detection; zip-based documents aren't mismatches, executables disguised as images are; cleanup by age and budget (skipping busy and hidden items); **drag-out resolution** (cancel/reject → keep, copy/generic → accepted, drop back onto Nook → keep) |
| Shelf at scale | 500 items: import, reopen, rebuild from sidecars |
| Notch state machine | hover → delay → expand → leave → collapse; a quick pass doesn't expand (including a late timer); moving between notch and panel doesn't flicker; re-entering while collapsing reopens; pinned and interaction lock; file drag from idle opens the drop target and ignores pointer noise; drag exit; drag-out holds the panel open; keyboard toggle with hover disabled; suspend/resume; Esc closes even when pinned |
| Notch geometry | the notch derived from real MacBook Pro `NSScreen` values (185×32 pt); calibration; fallback on a display without a notch; clamping to the screen |
| Settings | defaults valid; out-of-range values clamped; remote Ollama endpoint reset; unsafe hot key reset; corrupt or partial JSON tolerated; round trip |
| Ollama endpoint & client | loopback accepted; LAN, public, `nip.io`, `0.0.0.0`, credentials, path/query and non-HTTP rejected; cloud models filtered; connection refused → friendly error; streaming of content, thinking and stats; request body (`stream`, `think`, `num_ctx`); streamed error lines; **missing model reported, no pull request**; **cancellation stops the stream**; capability check and cloud refusal; `keep_alive: 0` |
| Think filter / Markdown / conversation | `<think>` split across chunks; blocks, an unterminated fence while streaming, code extraction; bounded context; local persistence; quick-action delimiting |
| Spotify logic | status parsing (including missing values and comma decimals); artwork host allow-list; playback clock interpolation and clamping; capability detection |

## Live and in-app checks

- **Live Ollama (opt-in):** `NOOK_LIVE_OLLAMA=1 scripts/test.sh --filter LiveOllama` streams a short reply from a local model, cancels mid-stream and unloads the model.
- **Sandboxed self-test:** `Nook --self-test` runs inside the signed, sandboxed app with temporary data only. It covers Shelf import/export, recovery, settings validation, the loopback-only Ollama policy and the launch-at-login location check. Add `--spotify` to include the Spotify checks (Spotify must be running).
- **Resource use:** `scripts/measure.sh 60 5` samples CPU, idle wake-ups, energy impact and memory of a running Nook. At idle with the panel closed, Nook should sit near 0 % CPU and well under 2 wake-ups/s.

## Not yet automated: manual checklist

These need a real pointer, drag sessions and on-screen judgement, so they aren't automated yet. Please run the relevant ones before opening a pull request that touches the UI.

1. **Hover**: rest on the notch, and the panel opens after about 0.1 s; a quick pass across doesn't open it; leaving closes it after the close delay; moving from notch to panel and back never flickers.
2. **Keyboard**: ⌥⌘N opens and closes; Esc closes; ⌘1/2/3 switch tabs; in the Shelf, ←/→, Space (Quick Look), Delete and ⌘V work.
3. **Menu bar**: each item works, including Pause Notch Hover and Settings.
4. **Drag in**: from Finder, drag one PDF, then 5 images at once onto the notch. It opens as "Release to add to Shelf"; items appear; the originals are still in Finder. Drag text from TextEdit, an image from Safari (promise/data), and a Mail attachment (promise).
5. **Drag cancel**: start dragging a tile out and press Esc or drop back on the panel. The item stays.
6. **Destination rejection**: drop a tile onto something that refuses files (e.g. the menu bar). It snaps back and stays.
7. **Drag out**: drop a tile on the Desktop. The file appears there and the tile hides, with Undo. Open the dropped copy to check it.
8. **Save a Copy As / Move To**: test with a name conflict (Keep Both / Replace / Cancel). The originals at the destination are untouched unless you confirmed Replace.
9. **Restart**: add items, quit (⌘Q from the menu), relaunch or restart the Mac. The items are still there.
10. **Display and power**: sleep/wake; connect or disconnect an external display (Nook stays on the built-in display); close the lid with an external display (hover off, shortcut opens the panel on the main display); a full-screen app.
11. **Music**: with Spotify playing, click Connect and approve. Check the artwork, the vinyl spinning and stopping on pause, seek, volume, next/previous.
12. **Assistant**: send a question; Stop mid-reply; copy a code block; To Shelf; New conversation; Unload.
    - Move the pointer from a reply's text down onto **Copy** / **To Shelf**: the buttons stay put and click. Paste elsewhere to confirm. Right-click the reply → Copy Reply / Copy Code / Save Reply to Shelf.
    - In the text box: ⌘A selects all, ⌘C/⌘X copy/cut, ⌘V pastes, ⌘Z undoes. Same in the Spotify search field and Settings fields. (Routing is self-tested; the real keystrokes are not.)
13. **Music panel (dark Liquid Glass)**: open the Music tab with a track loaded. Check:
    - Only 🔍 sits top-right.
    - Three separate glass droplets sit under the slider, with Play larger. They look three-dimensional: specular cap, delicate rim, faint rose caustic and floating shadow.
    - The blurred artwork is visibly lensed at the droplet edges.
    - Hover, press and keyboard focus (Tab) show their states.
    - Play, then pause: the vinyl stops in place, then resumes.
    - Change track: the artwork swaps without the vinyl jumping.
    - Close and reopen the panel while playing: the vinyl continues rather than restarting.
    - Try light and dark album art, *Reduce transparency* (solid surfaces) and *Reduce motion* (no spin, no scale effects).
    - Check that AI, Shelf, search and Settings feel like the same dark glass system.
14. **Search without setup**: 🔍 (or ⌘F), type "daft punk". You should see the setup notice, **Search in Spotify app** opens Spotify's search, and Esc returns to now playing.
15. **Search with setup** (optional): in Settings › Music › Catalogue search, follow steps 1–3 and Sign In. Then:
    - Type a query; results should appear after a short pause.
    - ↑/↓ highlight rows without playing anything.
    - ▶ (or Return on a highlighted row) plays the track, and the dock and now-playing area update.
    - Next continues within that track's album.
