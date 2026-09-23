#!/bin/bash
# Scale a tier's VMSS to an explicit instance count.
# Usage: scale.sh <web|api> <count>
#
# Note: both tiers have an autoscale policy (infra/terraform/modules/vmss)
# that reacts to CPU automatically; this script is for manual overrides
# (e.g. pre-scaling ahead of a known traffic spike) and always respects the
# min/max bounds set in Terraform - it will not fight the autoscaler for
# long, since autoscale re-evaluates every minute.
set -euo pipefail

TIER="${1:?usage: scale.sh <web|api> <count>}"
COUNT="${2:?usage: scale.sh <web|api> <count>}"
: "${RESOURCE_GROUP:?}" "${NAME_PREFIX:?}"

case "$TIER" in
  web|api) ;;
  *) echo "tier must be 'web' or 'api'" >&2; exit 1 ;;
esac

VMSS_NAME="${NAME_PREFIX}-vmss-${TIER}"

echo "Scaling ${VMSS_NAME} to ${COUNT} instances"
az vmss scale \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VMSS_NAME" \
  --new-capacity "$COUNT"
