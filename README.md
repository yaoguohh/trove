# Trove

**English** · [中文](README.zh-Hans.md)

[![Release](https://github.com/yaoguohh/trove/actions/workflows/release.yml/badge.svg)](https://github.com/yaoguohh/trove/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/yaoguohh/trove)](https://github.com/yaoguohh/trove/releases/latest)
[![License: MIT](https://img.shields.io/github/license/yaoguohh/trove)](LICENSE)
![Platform: macOS 14+, Apple Silicon and Intel](https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon%20%2B%20Intel-blue)

**Trove** keeps a trove of everything you copy — a keyboard-first, local-first macOS clipboard
manager. A floating panel of visual clip cards you summon, filter, preview, and paste, built
natively in Swift / AppKit + SwiftUI.

## Features

- Menu bar app — runs in the background with no Dock icon by default
- Visual horizontal timeline of clipboard history (text, links, images, code, email)
- **Keyboard-first**: the search field is always focused, so you just type to filter; ←/→ navigate the cards and Return pastes — no clicking, no lost first keystroke
- Global hotkey (default `⇧⌘V`), re-recordable right from the menu-bar menu
- **Space** peeks the selected card; tap the peek (or right-click **Preview**) to open a full-size inspect window with Keep-on-Top
- **Rich inspect window**: natively selectable text (⌘C / right-click Copy), pretty-printed JSON; a single URL opens in your default browser
- **⌘Z restores a just-deleted clip** — multi-level undo
- Handles huge clips gracefully — display & search stay snappy, large content spills to sidecar files
- **Rename** any clip inline in its header (the name is searchable too)
- Pinboards — each gets its own color — with home-screen-style drag-to-reorder
- Dock-style translucent glass panel in a single dark "anthracite" palette — one accent, three surface tiers, hairline edges
- Right-click the menu-bar icon for a compact menu — shortcut, link previews, and background mode, all inline (no separate Preferences window)
- Link title + favicon previews with local metadata caching (off by default — turn on **Link Previews** in the menu-bar menu; fetching tells the link's site that you copied it)
- In-app auto-updates via [Sparkle](https://sparkle-project.org)
- History keeps 500 unpinned clips by default (`defaults write io.github.yaoguohh.trove Trove.maxItems 1000` to change, 50–5000); pinned clips are never aged out

## Keyboard

Summon with `⇧⌘V`, then it's all keyboard:

| Key | Action |
|---|---|
| *type* | Filter the history (the search field is always focused) |
| `←` / `→` | Move the card selection |
| `⌘←` / `⌘→` | Jump a screenful at a time |
| `Return` | Paste the selected clip |
| `Space` | Quick-look peek bubble for the selected card |
| `⌦` / `⌘⌫` | Delete the selected clip |
| `⌘Z` | Restore the clip you just deleted (with an empty search) |
| `Esc` | Dismiss the peek → clear the search → close the panel |

Mouse: left-click the menu-bar icon to open or close the panel, right-click it for the menu. Hover a card for the **✎ rename** button; right-click a card for **Copy / Preview / Rename / Pin / Move to Pinboard / Delete**. Drag a card out to drop its content into another app.

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

Trove asks for two permissions; the menu-bar menu shows a warning row while either is missing:

- **Accessibility** (System Settings → Privacy & Security → Accessibility) lets Trove put the clip
  you choose into the app you were in — inserted directly where possible, with `⌘V` as the
  fallback. Without it, choosing a clip only copies it to the clipboard.
- **Pasteboard access** (macOS 15.4 and later): in System Settings → Privacy & Security, set
  Trove to **Always Allow**, or macOS asks every time Trove records a copy — and Trove records
  nothing when it is set to Deny. The menu-bar menu's **Allow Clipboard Access…** row opens that page.

## Privacy

Everything stays on your Mac.

- **What is kept**: text and images you copy, with the name of the app you copied from. Anything
  marked as concealed or transient — password managers, text expanders — is skipped before it is
  read.
- **Where**: `~/Library/Application Support/Trove/` — `history.json`, plus `images/` and `texts/`
  for images and very large text. It is not encrypted. Deleting a clip keeps its files until the
  undo history (25 deletes) moves past it; **Clear History** removes every unpinned clip and its
  files at once.
- **Network**: Trove goes online for two things only. *Update checks* (Sparkle) ask GitHub whether
  a newer version exists. *Link previews*, off by default, fetch a copied link's page title and
  icon — the query and fragment are stripped first, but the site learns the link was copied, and a
  one-time link whose token is in the path could be used up. Their cache lives in
  `~/Library/Caches/Trove/`.
- **Removing everything**: quit Trove, then delete `~/Library/Application Support/Trove/` and
  `~/Library/Caches/Trove/`.

## Updates

Trove checks for updates automatically in the background and via **menu bar → “Check for
Updates…”**, using Sparkle with EdDSA-signed appcasts (independent of Apple notarization).

## Build (from source)

```bash
swift build
swift test
```

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for running a full build locally, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code is organized (both in Chinese).

## Package a signed `.app`

```bash
bash scripts/package-app.sh        # → .build/Trove.app
```

Environment variables (all optional for local dev):

| Variable | Purpose |
|---|---|
| `TROVE_SU_PUBLIC_KEY` | Sparkle EdDSA **public** key → `SUPublicEDKey` in Info.plist (required for release builds) |
| `TROVE_SU_FEED_URL` | Appcast URL → `SUFeedURL` (defaults to the latest GitHub Release's `appcast.xml`) |
| `TROVE_CODESIGN_IDENTITY` | A real signing identity; without it the app is ad-hoc signed |
| `TROVE_MARKETING_VERSION` / `TROVE_BUILD_VERSION` | Version and build number; default to the latest tag + `-dev` and the commit count |

The app is a universal binary (Apple Silicon and Intel).

## Releasing

See [RELEASE.md](RELEASE.md) for the full maintainer runbook (one-time Sparkle key setup, per-release
build → appcast → GitHub Release steps, and the hard constraints to never break).

## License

[MIT](LICENSE) © 2026 yaoguohh
