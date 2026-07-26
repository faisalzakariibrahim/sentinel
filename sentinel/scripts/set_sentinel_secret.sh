#!/usr/bin/env bash
set -euo pipefail

# Helper: generate or use provided password and attempt to store it
# - If SUPABASE_PROJECT_REF and supabase CLI are available, tries to set a secret
# - If DATABASE_URL is set, will run an ALTER ROLE command via psql
# Usage:
#   SENTINEL_PASSWORD=... SUPABASE_PROJECT_REF=... ./scripts/set_sentinel_secret.sh

if [ -z "${SENTINEL_PASSWORD:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    SENTINEL_PASSWORD=$(openssl rand -base64 32)
  else
    SENTINEL_PASSWORD=$(head -c 24 /dev/urandom | base64)
  fi
fi

echo "Generated sentinel_executor password: $SENTINEL_PASSWORD"

# Try supabase CLI secret set (best-effort)
if command -v supabase >/dev/null 2>&1 && [ -n "${SUPABASE_PROJECT_REF:-}" ]; then
  echo "Attempting to store secret via supabase CLI for project $SUPABASE_PROJECT_REF"
  supabase secrets set SENTINEL_EXECUTOR_PASSWORD="$SENTINEL_PASSWORD" --project "$SUPABASE_PROJECT_REF" || true
fi

# If DATABASE_URL is provided, apply password directly to the DB
if [ -n "${DATABASE_URL:-}" ]; then
  echo "Applying role password via psql to DATABASE_URL"
  if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found in PATH; cannot apply password via psql" >&2
    exit 1
  fi
  echo "ALTER ROLE sentinel_executor WITH PASSWORD '$SENTINEL_PASSWORD';" | psql "$DATABASE_URL"
fi

echo "Done. Keep the generated password secure; do not commit it."
