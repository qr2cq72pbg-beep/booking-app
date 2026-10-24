#!/usr/bin/env bash
# XBOOK — Storage cleanup for the 15 candidate objects ONLY.
#
# NOT APPROVED. Refuses to run unless:
#   XBOOK_CONFIRM_STORAGE_DELETE=DELETE_CANDIDATE_STORAGE
# is set in the environment.
#
# Does not touch retained folders:
#   bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb
#   4fb21268-7a4d-4c62-8c0a-30f7571eac41
set -euo pipefail

if [[ "${XBOOK_CONFIRM_STORAGE_DELETE:-}" != "DELETE_CANDIDATE_STORAGE" ]]; then
  echo "Blocked: set XBOOK_CONFIRM_STORAGE_DELETE=DELETE_CANDIDATE_STORAGE only after written deletion approval AND a completed Storage backup." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RETAINED_A="bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb"
RETAINED_B="4fb21268-7a4d-4c62-8c0a-30f7571eac41"

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

cd "$ROOT"

for src in "${OBJECTS[@]}"; do
  case "$src" in
    *"$RETAINED_A"*|*"$RETAINED_B"*)
      echo "Refusing to delete a retained-business path: $src" >&2
      exit 1
      ;;
  esac
done

echo "Would delete ${#OBJECTS[@]} candidate Storage objects."
echo "Run with a second confirmation is still required: this script is a procedure, not an approved action."
echo "To actually delete after written approval, uncomment the rm loop below."
exit 1

# for src in "${OBJECTS[@]}"; do
#   supabase storage rm --linked "$src"
# done
