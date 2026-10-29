# Security policy

## Supported versions

Only the latest release on the `main` branch receives security fixes.

## Reporting a vulnerability

Please **don't open a public issue** for security problems.

Report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Include:

- what you found and where (file, setting or flow)
- steps to reproduce, ideally with a minimal example
- the impact you expect (for example: data loss on the Shelf, a non-loopback request from the Assistant, a token exposed in logs)

You should get an acknowledgement within 7 days. Once a fix is ready, it will be released and credited to you unless you'd rather stay anonymous.

## What counts as in scope

Nook makes specific promises, and any way around them is a security bug:

- The Assistant only ever talks to a **loopback** Ollama endpoint and refuses cloud models.
- The Shelf **never modifies or deletes the original** of anything you add, and never silently overwrites a file when exporting.
- Network requests go only to the destinations listed in the README's *Privacy* section.
- Spotify tokens are stored only in the Keychain and never written to logs or diagnostics.
- The app stays inside the App Sandbox with the entitlements in `Resources/Nook.entitlements`.

## Secrets in this repository

This repository contains **no API keys, client secrets or tokens**. Spotify catalogue search uses PKCE with each user's own Client ID, entered at runtime. A secret scan runs on every push and pull request (`.github/workflows/secret-scan.yml`). If you spot something that looks like a credential, report it privately as described above.
