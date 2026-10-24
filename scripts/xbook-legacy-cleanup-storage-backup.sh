#!/usr/bin/env bash
# XBOOK — download candidate Storage objects. Does not delete anything.
# Database dumps do not contain file bytes. Keep this folder off git.
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${XBOOK_BACKUP_DIR:-$HOME/xbook-legacy-cleanup-backups/$STAMP/storage}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RETAINED_A="bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb"
RETAINED_B="4fb21268-7a4d-4c62-8c0a-30f7571eac41"

# Exact live manifest from 9 Oct 2026 preflight (15 objects).
OBJECTS=(
  "ss:///business-gallery/4cd64220-f123-4eb6-a10b-dd6b66e6a685/1789578138301-872053f2-1000009440.jpg"
  "ss:///business-logos/41784a40-40e5-418d-9435-49ebab176196/cover.png"
  "ss:///business-logos/41784a40-40e5-418d-9435-49ebab176196/logo.png"
  "ss:///business-logos/41784a40-40e5-418d-9435-49ebab176196/staff/74610f55-d747-4e84-b79c-0af327fb0e6d.png"
  "ss:///business-logos/41784a40-40e5-418d-9435-49ebab176196/staff/7f6bce12-aa73-4b2d-b370-a4a31cdab3b7.png"
  "ss:///business-logos/41784a40-40e5-418d-9435-49ebab176196/staff/85aa5ffd-7261-4a05-97ab-bba08e38ac73.png"
  "ss:///business-logos/8bf87a44-4b05-4de6-aae0-2704b97b8dbd/logo.png"
  "ss:///business-logos/cc26d880-893c-4738-9d26-f9a0e15a03a6/cover.png"
  "ss:///business-logos/cc26d880-893c-4738-9d26-f9a0e15a03a6/logo.png"
  "ss:///business-logos/cc26d880-893c-4738-9d26-f9a0e15a03a6/staff/51e9c016-5997-4f51-b352-ffb6585807a0.png"
  "ss:///business-logos/cc26d880-893c-4738-9d26-f9a0e15a03a6/staff/e4b59a99-dee9-4a7e-9deb-9dbb8b35e4de.png"
  "ss:///business-logos/dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6/cover.jpg"
  "ss:///business-logos/dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6/logo.jpg"
  "ss:///business-logos/dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6/staff/b34eea4b-156d-4a70-83d3-2e1741d27456.jpg"
  "ss:///business-logos/dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6/staff/e01b7ca6-5910-4833-8bff-3659ab28cf3d.jpg"
)

mkdir -p "$OUT_DIR"
cd "$ROOT"

{
  echo "created_utc=$STAMP"
  echo "object_count=${#OBJECTS[@]}"
  echo "do_not_touch_folders=$RETAINED_A,$RETAINED_B"
  echo "bytes_note=re-query live sizes in supabase-legacy-business-cleanup-preflight.sql section K"
} > "$OUT_DIR/MANIFEST.txt"

for src in "${OBJECTS[@]}"; do
  case "$src" in
    *"$RETAINED_A"*|*"$RETAINED_B"*)
      echo "Refusing to download a retained-business path: $src" >&2
      exit 1
      ;;
  esac
  rel="${src#ss:///}"
  dest="$OUT_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  echo "Downloading $src"
  supabase storage cp --linked "$src" "$dest"
  echo "$rel" >> "$OUT_DIR/MANIFEST.txt"
done

echo
echo "Downloaded ${#OBJECTS[@]} objects to $OUT_DIR"
echo "Restore later with: supabase storage cp --linked <local-file> ss:///<bucket>/<path>"
echo "This script did not delete Storage objects."
