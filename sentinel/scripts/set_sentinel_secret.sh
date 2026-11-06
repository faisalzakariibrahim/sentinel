#!/usr/bin/env bash
set -euo pipefail

# Sets a real password on the sentinel_executor role and turns LOGIN on.
# Run it after the 20260726000001_sentinel_v2_security_fixes migration,
# which leaves the role disabled with no password.
#
# Targets (at least one is required):
#   DATABASE_URL          apply the password to the role via psql (psql 15+)
#   SUPABASE_PROJECT_REF  also store it as SENTINEL_EXECUTOR_PASSWORD with
#                         the supabase CLI (for Edge Functions)
#
# Options:
#   SENTINEL_PASSWORD     use this password instead of generating one
#   PRINT_PASSWORD=1      print the password once, e.g. to paste into your
#                         Vercel env for the cron executor
#
# Usage:
#   DATABASE_URL=postgres://... PRINT_PASSWORD=1 ./scripts/set_sentinel_secret.sh
#
# The password never appears in process arguments (visible to other users
# via ps) and is only printed when PRINT_PASSWORD=1.

use_db=false
use_supabase=false
[ -n "${DATABASE_URL:-}" ] && use_db=true
if [ -n "${SUPABASE_PROJECT_REF:-}" ]; then
  if command -v supabase >/dev/null 2>&1; then
    use_supabase=true
  else
    echo "SUPABASE_PROJECT_REF is set but the supabase CLI is not installed" >&2
    exit 1
  fi
fi

if ! $use_db && ! $use_supabase; then
  echo "Nothing to do: set DATABASE_URL and/or SUPABASE_PROJECT_REF." >&2
  echo "Refusing to generate a password that would not be stored anywhere." >&2
  exit 1
fi

if $use_db && ! command -v psql >/dev/null 2>&1; then
  echo "psql not found in PATH; cannot apply the password" >&2
  exit 1
fi

if [ -z "${SENTINEL_PASSWORD:-}" ]; then
  # hex: safe to paste into a postgres:// connection string unencoded
  if command -v openssl >/dev/null 2>&1; then
    SENTINEL_PASSWORD=$(openssl rand -hex 32)
  else
    SENTINEL_PASSWORD=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
fi
export SENTINEL_PASSWORD

if $use_db; then
  echo "Applying password and enabling login on sentinel_executor"
  # \getenv + :'pw' quotes the value safely; the password is read from the
  # environment, not passed on the command line.
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
\getenv pw SENTINEL_PASSWORD
alter role sentinel_executor with login password :'pw';
SQL
fi

if $use_supabase; then
  echo "Storing SENTINEL_EXECUTOR_PASSWORD for project $SUPABASE_PROJECT_REF"
  env_file=$(mktemp)
  chmod 600 "$env_file"
  trap 'rm -f "$env_file"' EXIT
  printf 'SENTINEL_EXECUTOR_PASSWORD=%s\n' "$SENTINEL_PASSWORD" > "$env_file"
  supabase secrets set --env-file "$env_file" --project-ref "$SUPABASE_PROJECT_REF"
fi

if [ "${PRINT_PASSWORD:-}" = "1" ]; then
  echo "sentinel_executor password: $SENTINEL_PASSWORD"
fi

echo "Done. Point the cron executor's DB client at sentinel_executor, not service_role."
