# ClipDeck

**English** · [中文](README.zh-Hans.md)

[![Release](https://github.com/yaoguohh/clipdeck/actions/workflows/release.yml/badge.svg)](https://github.com/yaoguohh/clipdeck/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/yaoguohh/clipdeck)](https://github.com/yaoguohh/clipdeck/releases/latest)
[![License: MIT](https://img.shields.io/github/license/yaoguohh/clipdeck)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)

ClipDeck is a local-first macOS clipboard manager — a keyboard-first floating panel of visual
clip cards, built natively in Swift / AppKit + SwiftUI.

## Features

- Menu bar app, optional background (accessory) mode
- Visual horizontal timeline of clipboard history (text, links, images, code, email, files)
- Global hotkey (default `⇧⌘V`), re-recordable in Preferences
- Keyboard-first flow: type to search, ←/→ to move, Return to paste, Esc to close
- Right-click **Preview** for a full-size, content-adaptive window (compare screenshots / long text)
- Pinboards (Favorites / Work / Code) with home-screen-style drag-to-reorder
- Dock-style translucent glass panel; light/dark via Preferences
- Link title + favicon previews with local metadata caching
- In-app auto-updates via [Sparkle](https://sparkle-project.org)
- Local JSON storage in `~/Library/Application Support/ClipDeck/`

## Install

Download the latest `ClipDeck.dmg` from the [Releases](https://github.com/yaoguohh/clipdeck/releases)
page, open it, and drag `ClipDeck.app` into the `Applications` folder.

### First launch (important)

ClipDeck is currently **not notarized by Apple** (no paid Developer account yet), so on first launch
macOS Gatekeeper will block it. This is a **one-time** step:

1. Double-click `ClipDeck.app` — macOS says it "cannot be opened".
2. Open **System Settings → Privacy & Security**, scroll to the Security section, and click
   **“Open Anyway”** next to ClipDeck. Confirm with your password.

(Terminal alternative: `xattr -dr com.apple.quarantine /Applications/ClipDeck.app`.)

After that one approval, **every future update installs silently** — Sparkle downloads updates over
its own connection and they never get quarantined, so Gatekeeper won't prompt again.

ClipDeck also needs **Accessibility permission** (System Settings → Privacy & Security →
Accessibility) to paste with a synthetic `⌘V` into the frontmost app.

## Updates

ClipDeck checks for updates automatically in the background and via **menu bar → “Check for
Updates…”**, using Sparkle with EdDSA-signed appcasts (independent of Apple notarization).

## Build (from source)

```bash
swift build
swift test
```

## Package a signed `.app`

```bash
bash scripts/package-app.sh        # → .build/ClipDeck.app
```

Environment variables (all optional for local dev):

| Variable | Purpose |
|---|---|
| `CLIPDECK_SU_PUBLIC_KEY` | Sparkle EdDSA **public** key → `SUPublicEDKey` in Info.plist (required for release builds) |
| `CLIPDECK_SU_FEED_URL` | Appcast URL → `SUFeedURL` (defaults to the repo's `appcast.xml`) |
| `CLIPDECK_CODESIGN_IDENTITY` | A real signing identity; defaults to ad-hoc signing |

## Releasing

See [RELEASE.md](RELEASE.md) for the full maintainer runbook (one-time Sparkle key setup, per-release
build → appcast → GitHub Release steps, and the hard constraints to never break).

## License

[MIT](LICENSE) © 2026 yaoguohh
