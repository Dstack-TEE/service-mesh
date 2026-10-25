#!/usr/bin/env bash
# Explicit staged provisioning breaks the dependency between CVM creation
# and the instance IDs peers need to address their signaling brokers.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <cluster-directory> [terraform-apply-options...]" >&2
  exit 2
fi
cluster_dir=$(realpath "$1")
shift
[[ -f "$cluster_dir/cluster.tf" ]] || { echo "Not a cluster directory: $cluster_dir" >&2; exit 2; }
parallelism=${DEPLOY_PARALLELISM-10}
[[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || {
  echo "DEPLOY_PARALLELISM must be a positive integer." >&2
  exit 2
}
for argument in "$@"; do
  case "$argument" in
    -target*|-replace*|-destroy*|-refresh-only*|-parallelism*|-var*|*.tfplan)
      echo "Set variables in terraform.tfvars; targeting, replacement, and saved plans are not supported by this driver." >&2
      exit 2 ;;
  esac
done
command -v jq >/dev/null
command -v curl >/dev/null
terraform_bin=${TERRAFORM_BIN:-terraform}
deploy_started=$SECONDS
"$terraform_bin" -chdir="$cluster_dir" init

echo "Stage 1: allocate the coordinator app without waiting for CVM boot."
"$terraform_bin" -chdir="$cluster_dir" apply -parallelism="$parallelism" \
  -var=coordinator_wait_for_ready=false -target=phala_app.coordinator "$@"
coordinator_app_id=$("$terraform_bin" -chdir="$cluster_dir" output -raw coordinator_app_id)
[[ "$coordinator_app_id" =~ ^app_[0-9a-f]{40}$ ]] || {
  echo "Invalid coordinator app identity returned by Terraform." >&2
  exit 1
}
roster_tmp=$(mktemp "$cluster_dir/.signaling-roster.XXXXXX")
trap 'rm -f -- "$roster_tmp"' EXIT
if [[ -f "$cluster_dir/signaling.auto.tfvars.json" ]]; then
  jq --arg id "$coordinator_app_id" '. + {coordinator_app_id: $id}' \
    "$cluster_dir/signaling.auto.tfvars.json" >"$roster_tmp"
else
  jq -n --arg id "$coordinator_app_id" '{coordinator_app_id: $id}' >"$roster_tmp"
fi
mv -- "$roster_tmp" "$cluster_dir/signaling.auto.tfvars.json"

echo "Stage 2: allocate coordinator instance identities without waiting for CVM boot."
"$terraform_bin" -chdir="$cluster_dir" apply -parallelism="$parallelism" \
  -var=coordinator_wait_for_ready=false -target=phala_app_instance.coordinator "$@"

# Keep subsequent plain plans/applies consistent. Re-run the driver after
# coordinator replacement/scaling to refresh this instance-pinned roster.
roster=$("$terraform_bin" -chdir="$cluster_dir" output -json coordinator_signaling_urls)
jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^https://[0-9a-f]+-7000\\.[A-Za-z0-9.-]+$"))' \
  <<<"$roster" >/dev/null
roster_tmp=$(mktemp "$cluster_dir/.signaling-roster.XXXXXX")
trap 'rm -f -- "$roster_tmp"' EXIT
jq -n --arg id "$coordinator_app_id" --argjson urls "$roster" \
  '{coordinator_app_id: $id, signaling_urls: $urls}' >"$roster_tmp"
mv -- "$roster_tmp" "$cluster_dir/signaling.auto.tfvars.json"

echo "Stage 3: distribute the broker roster and deploy/update all CVMs concurrently."
"$terraform_bin" -chdir="$cluster_dir" apply -parallelism="$parallelism" \
  -var=coordinator_wait_for_ready=true "$@"
while IFS= read -r endpoint; do
  protocol=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    --retry 5 --retry-delay 2 --retry-connrefused "$endpoint/healthz")
  [[ "$protocol" == "leaderless-signaling-v1" ]] || {
    echo "Coordinator does not run the leaderless signaling image: $endpoint" >&2
    exit 1
  }
done < <(jq -r '.[]' <<<"$roster")
echo "Deployment complete in $((SECONDS - deploy_started))s (parallelism=$parallelism)."
