#!/usr/bin/env bash
# Fail when the localizations drift from the code:
#   - every .lproj defines exactly the same keys;
#   - every key is used in Sources (no stale strings);
#   - every user-facing literal in Sources has a key.
# Interpolated keys are compared with their placeholders normalized: "Pinboard \(n)" ≙ "Pinboard %lld".
# Literals that must not be translated use `Text(verbatim:)`, which this check ignores.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -f "$TMP"/*; rmdir "$TMP"' EXIT

strings_keys() {
  grep -oE '^"[^"]+"' "$1" | sed -E 's/^"//; s/"$//; s/%(lld|ld|d|@)/%/g' | sort -u
}

# Literals passed to the SwiftUI / Foundation localizing initializers.
grep -rhoE '(Text\(|String\(localized:|Label\(|Button\(|Toggle\(|Menu\(|\.help\() *"[^"]+"' "$ROOT_DIR/Sources" \
  | sed -E 's/^[^"]*"//; s/"$//; s/\\\([^)]*\)/%/g; s/%(lld|ld|d|@)/%/g' | sort -u > "$TMP/code"

status=0
reference=""
for lproj in "$ROOT_DIR"/Localization/*.lproj; do
  name="$(basename "$lproj")"
  strings_keys "$lproj/Localizable.strings" > "$TMP/$name"
  if [[ -z "$reference" ]]; then
    reference="$name"
  elif ! diff -q "$TMP/$reference" "$TMP/$name" >/dev/null; then
    echo "error: $name and $reference define different keys:" >&2
    diff "$TMP/$reference" "$TMP/$name" >&2 || true
    status=1
  fi
done

unused="$(comm -23 "$TMP/$reference" "$TMP/code")"
missing="$(comm -13 "$TMP/$reference" "$TMP/code")"
if [[ -n "$unused" ]]; then
  echo "error: keys no code uses:" >&2
  echo "$unused" | sed 's/^/  /' >&2
  status=1
fi
if [[ -n "$missing" ]]; then
  echo "error: literals without a localization key:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  status=1
fi
if [[ $status -eq 0 ]]; then
  echo "Localizations match the code ($(wc -l < "$TMP/code" | tr -d ' ') keys)."
fi
exit $status
