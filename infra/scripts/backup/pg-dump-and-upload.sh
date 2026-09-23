#!/bin/bash
# Runs ON a single API-tier VMSS instance (it already has network access to
# the private DB subnet and a managed identity with:
#   - Key Vault Secrets User  (to fetch the DB password)
#   - Storage Blob Data Contributor on the backup storage account
# Triggered daily, against exactly one instance, by
# infra/scripts/backup/trigger-daily-backup.sh (run from CI) via
# `az vmss run-command invoke` - so backups are not duplicated across every
# autoscaled instance.
#
# `az vmss run-command invoke` passes --parameters as positional arguments
# to the script, so this reads $1..$6 rather than named env vars.
#   $1 DBHOST  $2 DBUSER  $3 DB  $4 DB_PASSWORD_SECRET_URI
#   $5 STORAGE_ACCOUNT  $6 STORAGE_CONTAINER
set -euo pipefail

DBHOST="${1:?DBHOST required}"
DBUSER="${2:?DBUSER required}"
DB="${3:?DB required}"
DB_PASSWORD_SECRET_URI="${4:?DB_PASSWORD_SECRET_URI required}"
STORAGE_ACCOUNT="${5:?STORAGE_ACCOUNT required}"
STORAGE_CONTAINER="${6:?STORAGE_CONTAINER required}"

command -v pg_dump >/dev/null 2>&1 || {
  apt-get update -y && apt-get install -y --no-install-recommends postgresql-client
}

imds_token() {
  # $1 = resource URI to request a token for
  curl -sf -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=$1" \
    | jq -r .access_token
}

DBPASS=$(curl -sf -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https://vault.azure.net" \
  | jq -r .access_token \
  | { read -r TOKEN; curl -sf -H "Authorization: Bearer $TOKEN" "${DB_PASSWORD_SECRET_URI}?api-version=7.4"; } \
  | jq -r .value)

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP_FILE="/tmp/${DB}-${TIMESTAMP}.sql.gz"
BLOB_NAME="${DB}/${TIMESTAMP}.sql.gz"

echo "Dumping ${DB}@${DBHOST} -> ${DUMP_FILE}"
PGPASSWORD="$DBPASS" pg_dump -h "$DBHOST" -U "$DBUSER" -d "$DB" --no-owner --format=plain \
  | gzip -9 > "$DUMP_FILE"

SIZE_BYTES=$(stat -c%s "$DUMP_FILE")
echo "Uploading ${SIZE_BYTES} bytes to ${STORAGE_ACCOUNT}/${STORAGE_CONTAINER}/${BLOB_NAME}"

STORAGE_TOKEN=$(imds_token "https://storage.azure.com/")
curl -sf -X PUT \
  -H "Authorization: Bearer ${STORAGE_TOKEN}" \
  -H "x-ms-version: 2021-08-06" \
  -H "x-ms-blob-type: BlockBlob" \
  -H "Content-Length: ${SIZE_BYTES}" \
  --data-binary "@${DUMP_FILE}" \
  "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${STORAGE_CONTAINER}/${BLOB_NAME}"

rm -f "$DUMP_FILE"
echo "Backup complete: ${BLOB_NAME}"
