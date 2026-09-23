#!/bin/bash
# Stop (deallocate, stop billing) all or one instance of a tier's VMSS.
# Usage: stop.sh <web|api> [instance-id]
set -euo pipefail

TIER="${1:?usage: stop.sh <web|api> [instance-id]}"
INSTANCE_ID="${2:-}"
: "${RESOURCE_GROUP:?}" "${NAME_PREFIX:?}"

case "$TIER" in
  web|api) ;;
  *) echo "tier must be 'web' or 'api'" >&2; exit 1 ;;
esac

VMSS_NAME="${NAME_PREFIX}-vmss-${TIER}"

if [ -n "$INSTANCE_ID" ]; then
  echo "Deallocating instance ${INSTANCE_ID} of ${VMSS_NAME}"
  az vmss deallocate --resource-group "$RESOURCE_GROUP" --name "$VMSS_NAME" --instance-ids "$INSTANCE_ID"
else
  echo "Deallocating ALL instances of ${VMSS_NAME}"
  az vmss deallocate --resource-group "$RESOURCE_GROUP" --name "$VMSS_NAME"
fi
