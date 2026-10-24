#!/usr/bin/env bash
# XBOOK — logical database backup for the legacy-business cleanup.
# Does not delete anything. Writes OUTSIDE the git repo by default.
#
# Restore test is required before any DELETE. Do not restore over production
# unless recovering from a failed cleanup.
set -euo pipefail

PROJECT_REF="${XBOOK_PROJECT_REF:-sdqothuulzeczcncyfqd}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${XBOOK_BACKUP_DIR:-$HOME/xbook-legacy-cleanup-backups/$STAMP}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$OUT_DIR"
echo "Writing backups to $OUT_DIR"

cd "$ROOT"

echo "== Schema dump (public + storage + auth catalogs as permitted) =="
supabase db dump --linked --keep-comments -f "$OUT_DIR/schema.sql"

echo "== Data dump (contains customer PII — keep this folder off git and off shared drives) =="
supabase db dump --linked --data-only --use-copy -f "$OUT_DIR/data.sql"

echo "== Storage metadata dump =="
supabase db dump --linked --data-only --use-copy --schema storage -f "$OUT_DIR/storage-metadata.sql" || {
  echo "storage-metadata dump skipped or failed; schema.sql + data.sql may still include storage.objects depending on privileges."
}

{
  echo "project_ref=$PROJECT_REF"
  echo "created_utc=$STAMP"
  echo "host=$(uname -n)"
  echo "schema_bytes=$(wc -c < "$OUT_DIR/schema.sql" | tr -d ' ')"
  echo "data_bytes=$(wc -c < "$OUT_DIR/data.sql" | tr -d ' ')"
} > "$OUT_DIR/MANIFEST.txt"

echo
echo "Backup written. Verify restore on a NEW empty database or local supabase, never on production:"
echo "  1. supabase projects create xbook-cleanup-restore-test   # or: supabase start"
echo "  2. psql \"\$RESTORE_DB_URL\" -v ON_ERROR_STOP=1 -f \"$OUT_DIR/schema.sql\""
echo "  3. psql \"\$RESTORE_DB_URL\" -v ON_ERROR_STOP=1 -f \"$OUT_DIR/data.sql\""
echo "  4. On the restore target, expect business_settings = 19, bookings total = 458"
echo "  5. Compare retained UUIDs:"
echo "       bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb"
echo "       4fb21268-7a4d-4c62-8c0a-30f7571eac41"
echo
echo "Dashboard physical backups (WALG=true, PITR=false as of preflight):"
echo "  supabase backups list --project-ref $PROJECT_REF"
echo "  Restore-to-a-new-project is safer than in-place restore."
echo
echo "This script did not delete or modify production data."
