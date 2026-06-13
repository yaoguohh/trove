# Trove

**English** · [中文](README.zh-Hans.md)

[![Release](https://github.com/yaoguohh/trove/actions/workflows/release.yml/badge.svg)](https://github.com/yaoguohh/trove/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/yaoguohh/trove)](https://github.com/yaoguohh/trove/releases/latest)
[![License: MIT](https://img.shields.io/github/license/yaoguohh/trove)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)

**Trove** keeps a trove of everything you copy — a keyboard-first, local-first macOS clipboard
manager. A floating panel of visual clip cards you summon, filter, preview, and paste, built
natively in Swift / AppKit + SwiftUI.

## Features

- Menu bar app — runs in the background with no Dock icon by default
- Visual horizontal timeline of clipboard history (text, links, images, code, email, files)
- **Keyboard-first**: the search field is always focused, so you just type to filter; ←/→ navigate the cards and Return pastes — no clicking, no lost first keystroke
- Global hotkey (default `⇧⌘V`), re-recordable right from the menu-bar menu
- **Space** peeks the selected card; tap the peek (or right-click **Preview**) to open a full-size inspect window with Keep-on-Top
- **Rich inspect window**: natively selectable text (⌘C / right-click Copy), pretty-printed JSON; a single URL opens in your default browser
- **⌘Z restores a just-deleted clip** — multi-level undo
- Handles huge clips gracefully — display & search stay snappy, large content spills to sidecar files
- **Rename** any clip inline in its header (the name is searchable too)
- Pinboards with custom colors and home-screen-style drag-to-reorder
- Dock-style translucent glass panel; light/dark right from the menu-bar menu
- Right-click the menu-bar icon for a compact menu — appearance, shortcut, link previews, and background mode, all inline (no separate Preferences window)
- Link title + favicon previews with local metadata caching
- In-app auto-updates via [Sparkle](https://sparkle-project.org)
- Local JSON storage in `~/Library/Application Support/Trove/`

## Keyboard

Summon with `⇧⌘V`, then it's all keyboard:

| Key | Action |
|---|---|
| *type* | Filter the history (the search field is always focused) |
| `←` / `→` | Move the card selection |
| `⌘←` / `⌘→` | Jump a screenful at a time |
| `Return` | Paste the selected clip |
| `⌥Return` | Paste as plain text |
| `Space` | Quick-look peek bubble for the selected card |
| `⌦` / `⌘⌫` | Delete the selected clip |
| `Esc` | Dismiss the peek → clear the search → close the panel |

Mouse: hover a card for the **✎ rename** button; right-click for **Copy / Preview / Rename / Pin / Add to Pinboard / Delete**. Drag a card out to drop its content into another app.

## Install

Download the latest `Trove.dmg` from the [Releases](https://github.com/yaoguohh/trove/releases)
page, open it, and drag `Trove.app` into the `Applications` folder.

### First launch (important)

Trove is currently **not notarized by Apple** (no paid Developer account yet), so on first launch
macOS Gatekeeper will block it. This is a **one-time** step:

1. Double-click `Trove.app` — macOS says it "cannot be opened".
2. Open **System Settings → Privacy & Security**, scroll to the Security section, and click
   **“Open Anyway”** next to Trove. Confirm with your password.

(Terminal alternative: `xattr -dr com.apple.quarantine /Applications/Trove.app`.)

After that one approval, **every future update installs silently** — Sparkle downloads updates over
its own connection and they never get quarantined, so Gatekeeper won't prompt again.

Trove also needs **Accessibility permission** (System Settings → Privacy & Security →
Accessibility) to paste with a synthetic `⌘V` into the frontmost app.

## Updates

Trove checks for updates automatically in the background and via **menu bar → “Check for
Updates…”**, using Sparkle with EdDSA-signed appcasts (independent of Apple notarization).

## Build (from source)

```bash
swift build
swift test
```

## Package a signed `.app`

```bash
bash scripts/package-app.sh        # → .build/Trove.app
```

Environment variables (all optional for local dev):

| Variable | Purpose |
|---|---|
| `TROVE_SU_PUBLIC_KEY` | Sparkle EdDSA **public** key → `SUPublicEDKey` in Info.plist (required for release builds) |
| `TROVE_SU_FEED_URL` | Appcast URL → `SUFeedURL` (defaults to the repo's `appcast.xml`) |
| `TROVE_CODESIGN_IDENTITY` | A real signing identity; defaults to ad-hoc signing |

## Releasing

See [RELEASE.md](RELEASE.md) for the full maintainer runbook (one-time Sparkle key setup, per-release
build → appcast → GitHub Release steps, and the hard constraints to never break).

## License

[MIT](LICENSE) © 2026 yaoguohh
