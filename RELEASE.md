# Releasing Trove

Trove ships on the **free distribution path**: ad-hoc signed, **not** notarized (no paid Apple
Developer account), with in-app auto-updates via **Sparkle** (EdDSA-signed appcast, independent of
Apple notarization). Distribution is **GitHub Releases** (Homebrew Cask optional, later). The app is
a universal binary (Apple Silicon and Intel) for macOS 14 and later.

> Background & rationale: two deep-research passes confirmed this is the standard setup for native
> open-source macOS tools (Maccy, Ice, Rectangle, Stats). Friction is one-time: users approve the
> first download once, then Sparkle updates install silently.

---

## One-time setup

### 1. Get Sparkle's command-line tools

`generate_keys` and `generate_appcast` ship in Sparkle's **binary tarball**, not via SwiftPM. The
script downloads the version `Package.resolved` pins (CI uses the same script):

```bash
bash scripts/fetch-sparkle-tools.sh /tmp/sparkle
ls /tmp/sparkle/bin   # generate_keys, generate_appcast, sign_update, ...
```

### 2. Generate the EdDSA update key (once, ever)

```bash
/tmp/sparkle/bin/generate_keys
```

- The **private** key is stored in your login Keychain. **Back it up** (`generate_keys -x
  private-key.pem`) and keep it secret — without a Developer ID you cannot recover from losing it.
- It prints the **public** key. Save it; that's your `TROVE_SU_PUBLIC_KEY`.

### 3. Appcast hosting (nothing to decide)

`SUFeedURL` points at `https://github.com/yaoguohh/trove/releases/latest/download/appcast.xml`.
CI uploads `appcast.xml` as a Release asset, and GitHub's `/releases/latest/download/` redirect
always serves the newest one — so the appcast is **never committed to the repo**.

---

## Cutting a release

### 1. Choose the version

Versions are passed via environment variables (no file edit needed):
- `TROVE_MARKETING_VERSION` (e.g. `0.2.0`) → `CFBundleShortVersionString`
- `TROVE_BUILD_VERSION` (**must increase monotonically every release** — Sparkle compares
  `CFBundleVersion` to decide "update available") → `CFBundleVersion`

**Releases are cut by pushing a tag** (`git tag v0.2.0 && git push origin v0.2.0`). CI derives the
marketing version from the tag and uses the workflow's `run_number` as the build number, which is the
single source of truth for `CFBundleVersion` (see `.github/workflows/release.yml`).

The manual steps below are an **emergency fallback** only. Before using them, read the build number
of the live feed and pick a larger one, or existing users will be told there is no update:

```bash
gh release download --pattern appcast.xml --dir /tmp/trove-feed --clobber
grep -o '<sparkle:version>[0-9]*' /tmp/trove-feed/appcast.xml
```

Local dev builds default to the commit count, so an installed dev build reads as newer than the
release it was cut from; never ship one.

### 2. Build the signed, Sparkle-embedded app

```bash
export TROVE_MARKETING_VERSION="0.2.0"
export TROVE_BUILD_VERSION="<larger than the live feed's sparkle:version>"
export TROVE_SU_PUBLIC_KEY="<public key from generate_keys>"
bash scripts/package-app.sh         # → .build/Trove.app (universal, ad-hoc, Sparkle embedded & signed)
```

Leave `TROVE_SU_FEED_URL` unset: the script's default is the Release-asset feed described above.

Sanity-check before shipping:

```bash
codesign --verify --deep --strict --verbose=2 .build/Trove.app   # must say "valid on disk"
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" -c "Print :SUFeedURL" \
  .build/Trove.app/Contents/Info.plist
```

### 3. Build the .dmg and generate the appcast

```bash
bash scripts/make-dmg.sh            # → dist/Trove.dmg (CI uses the same script)

# Reads the private key from your Keychain, writes appcast.xml with sparkle:edSignature + deltas.
# --download-url-prefix makes each enclosure point at the GitHub Release download URL.
/tmp/sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/yaoguohh/trove/releases/download/v0.2.0/" dist/
```

### 4. Publish

1. Create a GitHub Release tagged `v0.2.0`, uploading **both** `dist/Trove.dmg` and
   `dist/appcast.xml` as assets.
2. Done — `releases/latest/download/appcast.xml` now serves the new feed; existing users' Sparkle
   picks it up on the next check and updates silently. Nothing to commit to the repo.

---

## Hard constraints (breaking these breaks existing users' updates)

- **Keep the stable designated requirement.** `package-app.sh` ad-hoc signs the outer app with
  `--requirements '=designated => identifier "io.github.yaoguohh.trove"'`. **Never** regress to a bare
  `--sign -`, and **never change the bundle identifier** — Sparkle's update signature-match check
  (the no-Developer-ID fallback) relies on it, and TCC/Accessibility grants are keyed to it.
- **Never drop `SUPublicEDKey`** once a build has shipped with it, and put a matching
  `sparkle:edSignature` on **every** appcast entry. Sparkle supports key *rotation*, not *removal*.
- **Never enable Hardened Runtime / Library Validation** (`-o runtime`) on the ad-hoc path — it
  blocks Sparkle's framework from loading. (Only add it if you later notarize.)
- **Never `codesign --deep`.** Sparkle's nested XPC services are signed inner-out by the script; a
  `--deep` re-sign corrupts them.

## Later: Homebrew Cask & notarization

- **Homebrew Cask** (optional second install channel): a Cask pointing at the GitHub Release dmg,
  with `auto_updates true` (Sparkle owns updates). Can be a self-hosted tap first.
- **Notarization** (removes the first-launch friction): requires the Apple Developer Program
  ($99/yr) → Developer ID signing + `notarytool` + `stapler`. The packaging script already supports
  a real `TROVE_CODESIGN_IDENTITY`; add notarization steps when/if you buy the account.
