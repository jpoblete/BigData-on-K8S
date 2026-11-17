#!/usr/bin/env bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
# Apply the oracle.bigdata schema and trino grants to oracle-0 (FREEPDB1). Idempotent; safe to re-run.
# Sets the TRINO user's password from the hive-credentials Secret (oracle-trino-password), creating the
# Secret key first if missing. Needs kubectl access to namespace warehouse.
set -euo pipefail

NS="${NS:-warehouse}"
POD="${POD:-oracle-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure the trino password exists in the Secret (generated once, then reused).
if ! kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.oracle-trino-password}' 2>/dev/null | grep -q .; then
  NEWPW="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
  kubectl -n "${NS}" patch secret hive-credentials -p "{\"stringData\":{\"oracle-trino-password\":\"${NEWPW}\"}}" >/dev/null
fi
PW="$(kubectl -n "${NS}" get secret hive-credentials -o jsonpath='{.data.oracle-trino-password}' | base64 -d)"

# The pod is Ready once the listener answers. FREEPDB1 is created after that on a new volume.
echo "Waiting for Oracle FREEPDB1 to open ..."
kubectl -n "${NS}" exec -i "${POD}" -- bash -s <<'EOS'
set -euo pipefail
mode=""
for _ in $(seq 1 60); do
  mode="$(sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT open_mode FROM v$pdbs WHERE name = 'FREEPDB1';
EXIT
SQL
)"
  mode="$(printf '%s' "${mode}" | tr -d '[:space:]')"
  if [ "${mode}" = "READWRITE" ]; then
    exit 0
  fi
  sleep 10
done
echo "Timed out waiting for FREEPDB1 to open (last mode: ${mode:-none})" >&2
exit 1
EOS

# Apply schema and grants as SYSDBA in FREEPDB1. sqlplus must fail the script on ORA errors.
kubectl -n "${NS}" exec -i "${POD}" -- bash -c 'sqlplus -s / as sysdba' < "${HERE}/bigdata-schema.sql"

# Set the real TRINO password (the SQL sets a placeholder first). Keep the password out of the log.
kubectl -n "${NS}" exec -i "${POD}" -- env TRINO_PW="${PW}" bash -s <<'EOS'
set -euo pipefail
set +e
sqlplus -s / as sysdba > /tmp/ora-trino-pw.out 2>&1 <<SQL
WHENEVER SQLERROR EXIT FAILURE
SET ECHO OFF VERIFY OFF FEEDBACK OFF
ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER USER trino IDENTIFIED BY "${TRINO_PW}";
EXIT
SQL
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  sed -E 's/IDENTIFIED BY .*/IDENTIFIED BY ***/' /tmp/ora-trino-pw.out >&2
  rm -f /tmp/ora-trino-pw.out
  exit "${rc}"
fi
rm -f /tmp/ora-trino-pw.out
EOS

echo "applied oracle bigdata schema and trino grants to ${POD} (${NS}, FREEPDB1)"
