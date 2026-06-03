# Releasing ClipDeck

ClipDeck ships on the **free distribution path**: ad-hoc signed, **not** notarized (no paid Apple
Developer account), with in-app auto-updates via **Sparkle** (EdDSA-signed appcast, independent of
Apple notarization). Distribution is **GitHub Releases** (Homebrew Cask optional, later).

> Background & rationale: two deep-research passes confirmed this is the standard setup for native
> open-source macOS tools (Maccy, Ice, Rectangle, Stats). Friction is one-time: users approve the
> first download once, then Sparkle updates install silently.

---

## One-time setup

### 1. Get Sparkle's command-line tools

`generate_keys` and `generate_appcast` ship in Sparkle's **binary tarball**, not via SwiftPM:

```bash
# Match the version resolved in Package.resolved (currently 2.9.x)
curl -L -o /tmp/sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz
mkdir -p /tmp/sparkle && tar -xf /tmp/sparkle.tar.xz -C /tmp/sparkle
ls /tmp/sparkle/bin   # generate_keys, generate_appcast, sign_update, ...
```

### 2. Generate the EdDSA update key (once, ever)

```bash
/tmp/sparkle/bin/generate_keys
```

- The **private** key is stored in your login Keychain. **Back it up** (`generate_keys -x
  private-key.pem`) and keep it secret — without a Developer ID you cannot recover from losing it.
- It prints the **public** key. Save it; that's your `CLIPDECK_SU_PUBLIC_KEY`.

### 3. Appcast hosting (nothing to decide)

`SUFeedURL` points at `https://github.com/yaoguohh/clipdeck/releases/latest/download/appcast.xml`.
CI uploads `appcast.xml` as a Release asset, and GitHub's `/releases/latest/download/` redirect
always serves the newest one — so the appcast is **never committed to the repo**.

---

## Cutting a release

### 1. Choose the version

Versions are passed via environment variables (no file edit needed):
- `CLIPDECK_MARKETING_VERSION` (e.g. `0.2.0`) → `CFBundleShortVersionString`
- `CLIPDECK_BUILD_VERSION` (**must increase monotonically every release** — Sparkle compares
  `CFBundleVersion` to decide "update available") → `CFBundleVersion`

CI derives these from the tag + run number automatically (see `.github/workflows/release.yml`).

### 2. Build the signed, Sparkle-embedded app

```bash
export CLIPDECK_MARKETING_VERSION="0.2.0"
export CLIPDECK_BUILD_VERSION="2"                  # bump every release
export CLIPDECK_SU_PUBLIC_KEY="<public key from generate_keys>"
export CLIPDECK_SU_FEED_URL="https://raw.githubusercontent.com/yaoguohh/clipdeck/main/appcast.xml"
bash scripts/package-app.sh         # → .build/ClipDeck.app (ad-hoc, Sparkle embedded & signed)
```

Sanity-check before shipping:

```bash
codesign --verify --deep --strict --verbose=2 .build/ClipDeck.app   # must say "valid on disk"
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" -c "Print :SUFeedURL" \
  .build/ClipDeck.app/Contents/Info.plist
```

### 3. Zip it and generate the appcast

```bash
mkdir -p dist
ditto -c -k --keepParent .build/ClipDeck.app dist/ClipDeck.zip

# Reads the private key from your Keychain, writes appcast.xml with sparkle:edSignature + deltas.
# --download-url-prefix makes each enclosure point at the GitHub Release download URL.
/tmp/sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/yaoguohh/clipdeck/releases/download/v0.2.0/" dist/
```

### 4. Publish

1. Create a GitHub Release tagged `v0.2.0`, uploading **both** `dist/ClipDeck.zip` and
   `dist/appcast.xml` as assets.
2. Done — `releases/latest/download/appcast.xml` now serves the new feed; existing users' Sparkle
   picks it up on the next check and updates silently. Nothing to commit to the repo.

---

## Hard constraints (breaking these breaks existing users' updates)

- **Keep the stable designated requirement.** `package-app.sh` ad-hoc signs the outer app with
  `--requirements '=designated => identifier "dev.local.clipdeck"'`. **Never** regress to a bare
  `--sign -`, and **never change the bundle identifier** — Sparkle's update signature-match check
  (the no-Developer-ID fallback) relies on it, and TCC/Accessibility grants are keyed to it.
- **Never drop `SUPublicEDKey`** once a build has shipped with it, and put a matching
  `sparkle:edSignature` on **every** appcast entry. Sparkle supports key *rotation*, not *removal*.
- **Never enable Hardened Runtime / Library Validation** (`-o runtime`) on the ad-hoc path — it
  blocks Sparkle's framework from loading. (Only add it if you later notarize.)
- **Never `codesign --deep`.** Sparkle's nested XPC services are signed inner-out by the script; a
  `--deep` re-sign corrupts them.

## Later: Homebrew Cask & notarization

- **Homebrew Cask** (optional second install channel): a Cask pointing at the GitHub Release zip,
  with `auto_updates true` (Sparkle owns updates). Can be a self-hosted tap first.
- **Notarization** (removes the first-launch friction): requires the Apple Developer Program
  ($99/yr) → Developer ID signing + `notarytool` + `stapler`. The packaging script already supports
  a real `CLIPDECK_CODESIGN_IDENTITY`; add notarization steps when/if you buy the account.
