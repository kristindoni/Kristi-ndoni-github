#!/bin/bash
# One-time, run-once-by-hand setup for Terraform remote state. This is
# intentionally NOT itself Terraform: state storage has to exist before
# `terraform init -backend=...` can use it, so it's the one piece of infra
# bootstrapped imperatively via the Azure CLI.
#
# Usage: RESOURCE_GROUP=... STORAGE_ACCOUNT=... LOCATION=westeurope ./create-state-backend.sh
set -euo pipefail

: "${RESOURCE_GROUP:?}" "${STORAGE_ACCOUNT:?}"
LOCATION="${LOCATION:-westeurope}"

az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az storage account create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" \
  --sku Standard_GRS \
  --encryption-services blob \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

ACCOUNT_KEY=$(az storage account keys list --resource-group "$RESOURCE_GROUP" \
  --account-name "$STORAGE_ACCOUNT" --query "[0].value" -o tsv)

az storage container create \
  --name tfstate \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$ACCOUNT_KEY"

echo "Remote state backend ready:"
echo "  resource_group_name  = $RESOURCE_GROUP"
echo "  storage_account_name = $STORAGE_ACCOUNT"
echo "  container_name       = tfstate"
