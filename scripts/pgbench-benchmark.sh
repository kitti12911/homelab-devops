#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL pgbench benchmark — run before and after 4GB migration to compare.
# Usage: ./scripts/pgbench-benchmark.sh [init|run|all|cleanup]
#   init    — create pgbench tables (scale factor 100, ~1.6GB)
#   run     — execute read / mixed / write benchmarks at four concurrency levels
#   all     — init + run  (default)
#   cleanup — drop pgbench tables
# example: PG_RESULTS_DIR=pgbench-results-before ./scripts/pgbench-benchmark.sh


NAMESPACE="${PG_NAMESPACE:-database}"
POD="${PG_POD:-postgresql-1}"
DATABASE="${PG_DATABASE:-app}"
SCALE="${PG_SCALE:-100}"
DURATION="${PG_DURATION:-60}"
RESULTS_DIR="${PG_RESULTS_DIR:-pgbench-results}"

run_pgbench() {
  local label="$1"; shift
  echo ">>> [$label]"
  echo "    pgbench $*"
  kubectl exec -n "$NAMESPACE" "$POD" -- pgbench "$@" "$DATABASE" 2>&1 | tee -a "$RESULTS_DIR/$label.txt"
  echo ""
}

do_init() {
  echo "=== Initializing pgbench data (scale=$SCALE, ~$((SCALE * 16))MB) ==="
  kubectl exec -n "$NAMESPACE" "$POD" -- pgbench -i -s "$SCALE" "$DATABASE"
  echo ""
}

do_run() {
  mkdir -p "$RESULTS_DIR"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local summary="$RESULTS_DIR/summary-$ts.txt"

  {
    echo "pgbench benchmark — $(date)"
    echo "pod=$POD  namespace=$NAMESPACE  database=$DATABASE  scale=$SCALE  duration=${DURATION}s"
    kubectl exec -n "$NAMESPACE" "$POD" -- psql -c "SHOW shared_buffers;" "$DATABASE" 2>/dev/null || true
    kubectl exec -n "$NAMESPACE" "$POD" -- psql -c "SHOW effective_cache_size;" "$DATABASE" 2>/dev/null || true
    kubectl exec -n "$NAMESPACE" "$POD" -- psql -c "SHOW work_mem;" "$DATABASE" 2>/dev/null || true
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
  echo "Compare before/after with:  diff pgbench-results-before/ pgbench-results-after/"
}

do_cleanup() {
  echo "=== Dropping pgbench tables ==="
  kubectl exec -n "$NAMESPACE" "$POD" -- psql -c "DROP TABLE IF EXISTS pgbench_accounts, pgbench_branches, pgbench_history, pgbench_tellers CASCADE;" "$DATABASE"
  echo "Done."
}

case "${1:-all}" in
  init)    do_init ;;
  run)     do_run ;;
  all)     do_init; do_run ;;
  cleanup) do_cleanup ;;
  *)
    echo "Usage: $0 [init|run|all|cleanup]"
    echo "  Environment variables: PG_NAMESPACE PG_POD PG_DATABASE PG_SCALE PG_DURATION PG_RESULTS_DIR"
    exit 1
    ;;
esac
