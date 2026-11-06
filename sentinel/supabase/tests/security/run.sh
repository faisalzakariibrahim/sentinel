#!/usr/bin/env bash
# Security regression suite for the Sentinel v2 schema.
#
# Spins up a throwaway local Postgres (15+), stubs the Supabase pieces the
# schema relies on (anon/authenticated roles, auth.uid(), default grants),
# applies the original v2 migration, runs attack checks, applies the
# security-fix migration, and runs them again.
#
# BEFORE FIX: FAIL lines are the vulnerabilities the fix closes.
# AFTER FIX:  every line must be PASS. The script exits 1 otherwise.
#
# Usage: ./run.sh            (PG_BIN defaults to `pg_config --bindir`)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
migrations=$(cd "$here/../../migrations" && pwd)
bin=${PG_BIN:-$(pg_config --bindir)}
pgdir=${PGTEST_DIR:-$(mktemp -d)}
port=${PGTEST_PORT:-54329}

as_pg() { if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$@"; else "$@"; fi; }
[ "$(id -u)" = 0 ] && chown postgres "$pgdir"

as_pg "$bin/initdb" -D "$pgdir/data" -A trust -U postgres >/dev/null
as_pg "$bin/pg_ctl" -D "$pgdir/data" -o "-p $port -k $pgdir -c listen_addresses=''" -l "$pgdir/log" start >/dev/null
trap 'as_pg "$bin/pg_ctl" -D "$pgdir/data" stop -m fast >/dev/null' EXIT

psql_() { psql -h "$pgdir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -X "$@"; }
checks() { psql_ -f "$1" 2>&1 | grep -E "PASS|FAIL" | sed 's/^.*NOTICE:  //'; }

# pgvector may not be installed locally; the embedding column isn't under test
sed -e '/create extension if not exists vector/d' \
    -e 's/vector(1536)/real[]/' \
    -e '/using hnsw/d' \
    "$migrations/20260726000000_sentinel_v2_core.sql" > "$pgdir/v2_core_test.sql"

psql_ -q -f "$here/00_supabase_stub.sql"
psql_ -q -f "$pgdir/v2_core_test.sql"
psql_ -q -f "$here/10_seed.sql"

echo "================ BEFORE FIX (original v2 schema) ================"
checks "$here/20_checks.sql"

psql_ -q -f "$migrations/20260726000001_sentinel_v2_security_fixes.sql"

echo "================ AFTER FIX ================"
after=$( { checks "$here/20_checks.sql"; checks "$here/30_admin_checks.sql"; } )
echo "$after"
fails=$(echo "$after" | grep -c '^FAIL' || true)
echo "----------------"
echo "$(echo "$after" | grep -c '^PASS') passed, $fails failed"
[ "$fails" = 0 ]
