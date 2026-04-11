#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL pgbench benchmark — run from a local network device (e.g. MacBook).
# This measures DB performance + network latency (contrast with pgbench-benchmark.sh
# which runs in-pod and measures pure DB performance).
#
# Uses a dedicated 'pgbench' database owned by admin to avoid permission issues
# with the 'app' database (owned by the app user).
#
# Connection modes:
#   PG_HOST=<ip>  — connect directly (e.g. via NodePort on port 30432)
#   (no PG_HOST)  — auto kubectl port-forward through the k8s service
#
# Usage: ./scripts/pgbench-benchmark-local.sh [init|run|all|cleanup]
#   init    — create the pgbench database + tables (scale factor 100, ~1.6GB)
#   run     — execute read / mixed / write benchmarks at four concurrency levels
#   all     — init + run  (default)
#   cleanup — drop the pgbench database entirely
#
# Examples:
#   # Direct via NodePort (no port-forward overhead):
#   PG_HOST=192.168.1.100 PG_PASSWORD=… ./scripts/pgbench-benchmark-local.sh all
#
#   # Auto port-forward (fallback):
#   PG_PASSWORD=… ./scripts/pgbench-benchmark-local.sh all
#
# Prerequisites:
#   brew install libpq          # provides pgbench & psql on macOS
#   export PG_PASSWORD=$(kubectl get secret -n database postgresql-admin-secret \
#     -o jsonpath='{.data.password}' | base64 -d)

# export PG_PASSWORD=$(kubectl get secret -n database postgresql-admin-secret -o jsonpath='{.data.password}' | base64 -d)
# PG_HOST=192.168.88.205 ./scripts/pgbench-benchmark-local.sh all

NAMESPACE="${PG_NAMESPACE:-database}"
DATABASE="${PG_DATABASE:-pgbench}"
SCALE="${PG_SCALE:-100}"
DURATION="${PG_DURATION:-60}"
RESULTS_DIR="${PG_RESULTS_DIR:-pgbench-results-local}"
PG_USER="${PG_USER:-admin}"

# Direct connection (PG_HOST set) or port-forward (PG_HOST empty)
PG_HOST="${PG_HOST:-}"
PG_PORT="${PG_PORT:-30432}"
PG_SERVICE="${PG_SERVICE:-postgresql-rw}"
PG_SERVICE_PORT="${PG_SERVICE_PORT:-5432}"
LOCAL_PORT="${PG_LOCAL_PORT:-55432}"

PORT_FWD_PID=""
USE_PORT_FORWARD=false

die() { echo "ERROR: $*" >&2; exit 1; }

cleanup_port_forward() {
  if [[ -n "$PORT_FWD_PID" ]]; then
    kill "$PORT_FWD_PID" 2>/dev/null || true
    wait "$PORT_FWD_PID" 2>/dev/null || true
    PORT_FWD_PID=""
  fi
}

start_port_forward() {
  echo "=== Port-forwarding localhost:$LOCAL_PORT → svc/$PG_SERVICE:$PG_SERVICE_PORT ==="
  kubectl port-forward -n "$NAMESPACE" "svc/$PG_SERVICE" "$LOCAL_PORT:$PG_SERVICE_PORT" &>/dev/null &
  PORT_FWD_PID=$!
  trap cleanup_port_forward EXIT INT TERM
  sleep 2
  kill -0 "$PORT_FWD_PID" 2>/dev/null || die "port-forward failed to start"
  echo "    port-forward running (pid=$PORT_FWD_PID)"
}

resolve_connection() {
  if [[ -n "$PG_HOST" ]]; then
    CONN_HOST="$PG_HOST"
    CONN_PORT="$PG_PORT"
    CONN_LABEL="$PG_HOST:$PG_PORT"
  else
    USE_PORT_FORWARD=true
    CONN_HOST="localhost"
    CONN_PORT="$LOCAL_PORT"
    CONN_LABEL="localhost:$LOCAL_PORT (port-forward)"
  fi
}

pgbench_local() {
  PGPASSWORD="$PG_PASSWORD" pgbench -h "$CONN_HOST" -p "$CONN_PORT" -U "$PG_USER" "$@"
}

psql_local() {
  PGPASSWORD="$PG_PASSWORD" psql -h "$CONN_HOST" -p "$CONN_PORT" -U "$PG_USER" "$@"
}

run_pgbench() {
  local label="$1"; shift
  echo ">>> [$label]"
  echo "    pgbench (local → $CONN_LABEL) $*"
  pgbench_local "$@" "$DATABASE" 2>&1 | tee -a "$RESULTS_DIR/$label.txt"
  echo ""
}

do_init() {
  echo "=== Creating database '$DATABASE' (owner: $PG_USER) ==="
  psql_local -d postgres -c "CREATE DATABASE $DATABASE OWNER $PG_USER;" 2>/dev/null \
    || echo "    (database already exists, skipping)"
  echo ""
  echo "=== Initializing pgbench data (scale=$SCALE, ~$((SCALE * 16))MB) ==="
  pgbench_local -i -s "$SCALE" "$DATABASE"
  echo ""
}

do_run() {
  mkdir -p "$RESULTS_DIR"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local summary="$RESULTS_DIR/summary-$ts.txt"

  {
    echo "pgbench benchmark (LOCAL) — $(date)"
    echo "database=$DATABASE  scale=$SCALE  duration=${DURATION}s"
    echo "target=$CONN_LABEL  pg_user=$PG_USER  namespace=$NAMESPACE"
    psql_local -c "SHOW shared_buffers;" "$DATABASE" 2>/dev/null || true
    psql_local -c "SHOW effective_cache_size;" "$DATABASE" 2>/dev/null || true
    psql_local -c "SHOW work_mem;" "$DATABASE" 2>/dev/null || true
    echo "---"
    echo ""
  } | tee "$summary"

  echo "=== Read-only (SELECT) ==="
  run_pgbench "read-c10"  -S -c 10 -j 2 -T "$DURATION"
  run_pgbench "read-c50"  -S -c 50 -j 4 -T "$DURATION"
  run_pgbench "read-c75"  -S -c 75 -j 4 -T "$DURATION"
  run_pgbench "read-c90"  -S -c 90 -j 4 -T "$DURATION"

  echo "=== Mixed (TPC-B default) ==="
  run_pgbench "mixed-c10" -c 10 -j 2 -T "$DURATION"
  run_pgbench "mixed-c50" -c 50 -j 4 -T "$DURATION"
  run_pgbench "mixed-c75" -c 75 -j 4 -T "$DURATION"
  run_pgbench "mixed-c90" -c 90 -j 4 -T "$DURATION"

  echo "=== Write-heavy (-N, skip branch updates) ==="
  run_pgbench "write-c10" -N -c 10 -j 2 -T "$DURATION"
  run_pgbench "write-c50" -N -c 50 -j 4 -T "$DURATION"
  run_pgbench "write-c75" -N -c 75 -j 4 -T "$DURATION"
  run_pgbench "write-c90" -N -c 90 -j 4 -T "$DURATION"

  echo ""
  echo "=== Done. Results saved to $RESULTS_DIR/ ==="
  echo "Compare local vs in-pod:  diff pgbench-results-local/ pgbench-results/"
}

do_cleanup() {
  echo "=== Dropping database '$DATABASE' ==="
  psql_local -d postgres -c "DROP DATABASE IF EXISTS $DATABASE;"
  echo "Done."
}

# --- preflight checks ---
command -v pgbench &>/dev/null || die "pgbench not found. Install with:  brew install libpq"
command -v psql &>/dev/null   || die "psql not found. Install with:  brew install libpq"
[[ -n "${PG_PASSWORD:-}" ]]   || die "PG_PASSWORD required. Run:  export PG_PASSWORD=\$(kubectl get secret -n $NAMESPACE postgresql-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

resolve_connection

if [[ "$USE_PORT_FORWARD" == true ]]; then
  start_port_forward
else
  echo "=== Connecting directly to $CONN_LABEL ==="
fi

case "${1:-all}" in
  init)    do_init ;;
  run)     do_run ;;
  all)     do_init; do_run ;;
  cleanup) do_cleanup ;;
  *)
    echo "Usage: $0 [init|run|all|cleanup]"
    echo ""
    echo "Environment variables:"
    echo "  PG_PASSWORD      PostgreSQL password     (required)"
    echo "  PG_HOST          node IP for direct conn (default: unset → port-forward)"
    echo "  PG_PORT          node port               (default: 30432)"
    echo "  PG_USER          PostgreSQL user          (default: admin)"
    echo "  PG_DATABASE      database name            (default: pgbench)"
    echo "  PG_NAMESPACE     k8s namespace             (default: database)"
    echo "  PG_SCALE         scale factor              (default: 100)"
    echo "  PG_DURATION      seconds per test          (default: 60)"
    echo "  PG_RESULTS_DIR   output directory          (default: pgbench-results-local)"
    echo ""
    echo "Port-forward only (when PG_HOST is not set):"
    echo "  PG_SERVICE       k8s service name          (default: postgresql-rw)"
    echo "  PG_SERVICE_PORT  service port              (default: 5432)"
    echo "  PG_LOCAL_PORT    local forward port        (default: 55432)"
    exit 1
    ;;
esac
