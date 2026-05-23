#!/usr/bin/env bash
# Workload-aware rolling update driver.
#
# STATUS: paused. The provider 0.3 beta line has named slots and
# app-revision fan-out support, but this script has not yet been updated
# for the workload-group topology or for workload-aware drain ordering.
# Direct Terraform apply is the supported path for now.
#
# The wait_for_quorum_healthy + snapshot helpers below are still useful
# scaffolding for a future workload-aware rollout, so they're kept. The
# execution section is a clear error until the rollout behavior is made
# explicit again.
#
# Usage:
#   ./rollout.sh --plan                # snapshot + plan (no apply)
#   ./rollout.sh                       # currently exits with a guidance message
#
# Requires:
#   PHALA_CLOUD_API_KEY env (or terraform `phala` provider config)
#   terraform CLI on PATH
#   A working overlay (mesh-conn + Consul) so we can query cluster health.

set -euo pipefail

# ---------- Config ----------

MIN_READY_SECONDS="${MIN_READY_SECONDS:-30}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"

PLAN_ONLY=false
APP_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)  PLAN_ONLY=true; shift ;;
    --app)   APP_FILTER="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ---------- Helpers ----------

CONSUL_BASE=""

resolve_consul_base() {
  local consul_ui
  consul_ui=$(terraform output -raw consul_ui 2>/dev/null || echo "")
  if [[ -z "$consul_ui" ]]; then
    echo "ERROR: terraform output consul_ui missing; run terraform apply at least once" >&2
    exit 1
  fi
  # `<port>` (no trailing 's') — gateway terminates TLS, backend is
  # plain HTTP. The `<port>s` pass-through form is for backends that
  # speak TLS themselves; Consul's HTTP API does not.
  CONSUL_BASE="${consul_ui%/ui}"
}

consul_members_alive() {
  curl -sf "${CONSUL_BASE}/v1/agent/members" \
    | jq -r '[.[] | select(.Status==1)] | length' 2>/dev/null \
    || echo 0
}

consul_leader_present() {
  local lead
  lead=$(curl -sf "${CONSUL_BASE}/v1/status/leader" 2>/dev/null || echo '""')
  [[ "$lead" != '""' && -n "$lead" ]]
}

wait_for_quorum_healthy() {
  local expected="$1"
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  while (( $(date +%s) < deadline )); do
    local alive
    alive=$(consul_members_alive)
    if [[ "$alive" == "$expected" ]] && consul_leader_present; then
      sleep "$MIN_READY_SECONDS"
      # re-check after the cool-off
      alive=$(consul_members_alive)
      if [[ "$alive" == "$expected" ]] && consul_leader_present; then
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}

snapshot_consul() {
  local label="$1"
  local snap_dir="snapshots"
  local f
  mkdir -p "$snap_dir"
  f="$snap_dir/${label}-$(date +%Y%m%d-%H%M%S).snap"
  if curl -sf -X PUT "${CONSUL_BASE}/v1/snapshot" -o "$f"; then
    echo "snapshot saved: $f"
  else
    echo "WARN: snapshot save failed (continuing)" >&2
  fi
}

# Transfer Raft leader off the named node if it's currently leader.
# No-op if some other node is leader.
maybe_transfer_leader() {
  local current_node="$1"
  local lead
  lead=$(curl -sf "${CONSUL_BASE}/v1/status/leader" 2>/dev/null | jq -r .)
  echo "current leader: $lead; this node: $current_node"
  # Heuristic: if leader contains current_node's RPC port, transfer.
  if [[ "$lead" == *":${current_node}"* ]]; then
    echo "transferring leadership away from $current_node"
    curl -sf -X POST "${CONSUL_BASE}/v1/operator/raft/transfer-leader" >/dev/null \
      || echo "WARN: leader transfer rejected (likely single-server cluster)"
    sleep 5
  fi
}

# ---------- Main ----------

resolve_consul_base
echo "Consul UI base: $CONSUL_BASE"

EXPECTED=$(curl -sf "${CONSUL_BASE}/v1/agent/members" 2>/dev/null | jq -r 'length' || echo 0)
echo "current members alive: $(consul_members_alive) / $EXPECTED"

if ! consul_leader_present; then
  echo "ERROR: cluster has no leader; refusing to roll" >&2
  exit 1
fi

snapshot_consul "pre-rollout"

if $PLAN_ONLY; then
  terraform plan
  exit 0
fi

cat >&2 <<'EOF'

==============================================================================
rollout.sh is paused. The provider 0.3 beta line supports named slots and
app-revision fan-out, but this script has not yet been updated for the
current workload-group topology or for workload-aware drain ordering.

What works today:

  * Add a slot:    bump a workload replica variable (or coordinator_replicas) and
                   run `terraform apply` — the provider creates only the
                   new slot; existing slots keep their vm_uuids.
  * Remove a slot: lower the replicas count; only the high-ordinal slot
                   is destroyed.

What does NOT work (yet):

  * Use this script to roll a new docker compose / env / image across
    slots: the drain/order/app-targeting behavior has not been reworked
    for separate workload groups yet.

What we're waiting on:

  * A workload-aware rollout implementation that reuses the Consul
    health, snapshot, and leader-transfer scaffolding below while using
    the provider's app-revision fan-out path deliberately.

See ./PROGRESS.md for current status.
==============================================================================

EOF
exit 2
