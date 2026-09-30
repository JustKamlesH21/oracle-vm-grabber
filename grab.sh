#!/usr/bin/env bash
# Try to launch the Oracle Cloud Always Free Ampere VM until capacity frees up or the deadline passes.
# Runs in GitHub Actions (see .github/workflows/grab.yml); credentials come from encrypted secrets.
# Exit 0 = VM exists (created now or earlier), 2 = deadline reached without capacity, 1 = real error.
set -uo pipefail

NAME="${VM_NAME:-cti-verify}"
OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
DEADLINE=$(( $(date +%s) + ${MAX_MINUTES:-54} * 60 ))
SSH_PUB="${SSH_PUB:-$HOME/.ssh/vm.pub}"
TENANCY="$(awk -F= '/^tenancy=/{print $2; exit}' "$HOME/.oci/config" | tr -d ' ')"

log() { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
q() { oci "$@" --raw-output 2>/dev/null; }

existing="$(q compute instance list --compartment-id "$TENANCY" --display-name "$NAME" \
  --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id")"
if [[ -n "$existing" && "$existing" != "null" ]]; then
  log "VM '$NAME' already exists; nothing to do."; echo "created=existing" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0
fi

SUBNET="$(q network subnet list --compartment-id "$TENANCY" \
  --query "data[?\"prohibit-public-ip-on-vnic\"==\`false\` && \"lifecycle-state\"=='AVAILABLE'] | [0].id")"
[[ -n "$SUBNET" && "$SUBNET" != "null" ]] || { log "no public subnet found (create one with deploy/oracle-grab-vm.sh locally first)"; exit 1; }
IMAGE="$(q compute image list --compartment-id "$TENANCY" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
  --limit 1 --query 'data[0].id')"
ADS="$(q iam availability-domain list --compartment-id "$TENANCY" --query 'data[].name' | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')"
log "ready: image found, public subnet found, $(wc -w <<<"$ADS" | tr -d ' ') availability domain(s)"

attempt=0
while (( $(date +%s) < DEADLINE )); do
  for AD in $ADS; do
    attempt=$((attempt + 1))
    out="$(oci compute instance launch --compartment-id "$TENANCY" --availability-domain "$AD" \
      --display-name "$NAME" --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
      --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
      --boot-volume-size-in-gbs 50 --ssh-authorized-keys-file "$SSH_PUB" \
      --query 'data.id' --raw-output 2>&1)"
    if [[ "$out" == ocid1.instance.* ]]; then
      log "attempt $attempt: VM created. Waiting for RUNNING ..."
      oci compute instance get --instance-id "$out" --wait-for-state RUNNING --max-wait-seconds 900 >/dev/null 2>&1
      echo "created=new" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0
    fi
    case "$out" in
      *"Out of host capacity"*|*"out of capacity"*|*InternalError*|*TooManyRequests*) log "attempt $attempt: no capacity yet";;
      *LimitExceeded*|*QuotaExceeded*) log "attempt $attempt: Always Free limit reached (a VM may already exist)"; exit 1;;
      *NotAuthorized*|*NotAuthenticated*) log "attempt $attempt: authentication failed; check the OCI_* secrets"; exit 1;;
      *) log "attempt $attempt: unexpected response: $(grep -oE '"(code|message)": "[^"]*"' <<<"$out" | head -2 | tr '\n' ' ')";;
    esac
  done
  sleep $((50 + RANDOM % 41))
done
log "no capacity in this window after $attempt attempts; the next scheduled run continues."
exit 2
