#!/bin/bash
# Runs from CI (or any machine logged into Azure CLI with rights on the
# resource group) on a daily schedule. It does NOT need network access to
# the private DB subnet: it just asks Azure to run pg-dump-and-upload.sh on
# one API-tier instance via the VM agent's RunCommand extension, which
# executes inside the VNet where the DB is actually reachable.
#
# The PostgreSQL Flexible Server's own automated daily backups (configured
# in terraform/modules/database, backup_retention_days) are the primary,
# always-on safety net and require no script at all. This is a
# supplementary logical (pg_dump) export for portability/defense-in-depth.
set -euo pipefail

: "${RESOURCE_GROUP:?}" "${API_VMSS_NAME:?}" "${DB_HOST:?}" "${DB_USER:?}" \
  "${DB_NAME:?}" "${DB_PASSWORD_SECRET_URI:?}" "${STORAGE_ACCOUNT:?}" "${STORAGE_CONTAINER:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only ever target a single, currently-running instance so autoscaling
# doesn't fan this out into N duplicate dumps.
INSTANCE_ID=$(az vmss list-instances \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_VMSS_NAME" \
  --query "[?provisioningState=='Succeeded'] | [0].instanceId" -o tsv)

if [ -z "$INSTANCE_ID" ]; then
  echo "No healthy $API_VMSS_NAME instance found to run the backup on" >&2
  exit 1
fi

echo "Running backup on ${API_VMSS_NAME} instance ${INSTANCE_ID}"

az vmss run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$API_VMSS_NAME" \
  --instance-id "$INSTANCE_ID" \
  --command-id RunShellScript \
  --scripts "@${SCRIPT_DIR}/pg-dump-and-upload.sh" \
  --parameters "${DB_HOST}" "${DB_USER}" "${DB_NAME}" "${DB_PASSWORD_SECRET_URI}" \
               "${STORAGE_ACCOUNT}" "${STORAGE_CONTAINER}" \
  --query "value[0].message" -o tsv
