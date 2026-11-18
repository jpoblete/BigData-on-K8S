#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
#
# Cassandra counterpart of base/createTable.sh.
#
# c1 is a uuid partition key.
# c2 is an int clustering column: a calendar year, newest first (2026, 2025, ...).
# c3 is a timeuuid clustering column in ascending order, and each value falls in that c2 year.
# c4..cN are text. Each cell gets its own random value; a value is never copied across columns.
# text is not used for c2 or c3: Cassandra orders text by raw UTF-8 bytes, so "10" sorts
# before "2" and a year string does not sort as a number. int and timeuuid do.
#
# Run inside a cassandra pod (uses cql.sh, which uses the entrypoint kinit ticket):
#   createCassandraTable.sh keyspace table_name cols_number partitions clusters rows
#
#   keyspace    : existing keyspace, or created with replication from KS_RF (default 3)
#                 and KS_RF_TRINO (default 1)
#   table_name  : table name, for example dummy_10_10_10
#   cols_number : number of columns, minimum 3 (default 3)
#   partitions  : distinct c1 values, minimum 1 (default 10)
#   clusters    : distinct c2 years per partition, counting back from this year, minimum 1 (default 10)
#   rows        : distinct c3 timeuuids in each year, ascending, minimum 1 (default 10)
#
# Total rows = partitions * clusters * rows. Rows in one partition = clusters * rows.
# Example: createCassandraTable.sh demo dummy_10_10_10 10 10 10
#   10 columns (c4..c10 text), 10 partitions, years 2026..2017, 10 timeuuids per year
#   1000 rows, 100 in each partition

set -o pipefail

KEYSPACE="${1:-}"
TBL_NAME="${2:-}"
TBL_COLS="${3:-3}"
PARTITIONS="${4:-10}"
CLUSTERS="${5:-10}"
ROWS="${6:-10}"
START_YEAR="$(date +%Y)"
KS_RF="${KS_RF:-3}"
KS_RF_TRINO="${KS_RF_TRINO:-1}"
CQL_SH="${CQL_SH:-cql.sh}"
TIMESTAMP=$(date "+%s")
CQL_FILE="/tmp/createCassandraTable.${TIMESTAMP}.cql"

# Print command usage and describe each positional argument.
usage() {
   echo "createCassandraTable.sh keyspace table_name cols_number partitions clusters rows"
   echo "Set CREATE_TABLE_VERBOSE=1 to print generated CQL before it runs."
   echo "keyspace    : keyspace name (created if missing, RF from KS_RF, default 3)"
   echo "table_name  : table name, for example dummy_10_10_10"
   echo "cols_number : number of columns, minimum 3 (default 3)"
   echo "             : c1 uuid, c2 int year DESC, c3 timeuuid ASC, c4..cN text"
   echo "partitions  : distinct c1 values, minimum 1 (default 10)"
   echo "clusters    : c2 years per partition, counting back from this year, minimum 1 (default 10)"
   echo "rows        : c3 timeuuids in each year, ascending, minimum 1 (default 10)"
   echo "total rows  : partitions * clusters * rows"
}

# Print an error message, show usage, and stop the script.
die() {
   echo "ERROR: $*" >&2
   usage >&2
   exit 1
}

# Return success when the provided value is an unsigned integer.
is_uint() {
   [[ "$1" =~ ^[0-9]+$ ]]
}

# Validate a CQL identifier (unquoted: letters, digits, underscore, starting with a letter).
validate_identifier() {
   [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Validate user input before generating CQL.
validate_args() {
   [ -n "${KEYSPACE}" ] || die "keyspace needs to be specified"
   [ -n "${TBL_NAME}" ] || die "table_name needs to be specified"
   command -v python3 >/dev/null 2>&1 || die "python3 is required to build timeuuid values"
   validate_identifier "${KEYSPACE}" || die "invalid keyspace: ${KEYSPACE}"
   validate_identifier "${TBL_NAME}" || die "invalid table_name: ${TBL_NAME}"
   is_uint "${KS_RF}"       || die "KS_RF must be a positive integer"
   is_uint "${KS_RF_TRINO}" || die "KS_RF_TRINO must be a positive integer"
   is_uint "${TBL_COLS}"    || die "cols_number must be a positive integer"
   is_uint "${PARTITIONS}"  || die "partitions must be a positive integer"
   is_uint "${CLUSTERS}"    || die "clusters must be a positive integer"
   is_uint "${ROWS}"        || die "rows must be a positive integer"
   [ "${KS_RF}" -ge 1 ]       || die "KS_RF=${KS_RF}, cannot be less than 1"
   [ "${TBL_COLS}" -ge 3 ]    || die "cols_number=${TBL_COLS}, cannot be less than 3"
   [ "${PARTITIONS}" -ge 1 ]  || die "partitions=${PARTITIONS}, cannot be less than 1"
   [ "${CLUSTERS}" -ge 1 ]    || die "clusters=${CLUSTERS}, cannot be less than 1"
   [ "${ROWS}" -ge 1 ]        || die "rows=${ROWS}, cannot be less than 1"
}

# Join all remaining arguments using the first argument as separator.
join_by() {
   local sep="$1"
   shift

   local out=""
   local item

   for item in "$@"; do
      if [ -z "${out}" ]; then
         out="${item}"
      else
         out="${out}${sep}${item}"
      fi
   done

   printf "%s" "${out}"
}

# Generate a random alphanumeric string of the requested length.
genRandomStr() {
   local len="$1"
   local s=""
   local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

   while (( ${#s} < len )); do
      s+="${chars:RANDOM%62:1}"
   done

   printf "%s" "${s}"
}

# CREATE KEYSPACE if it does not exist.
createKeyspace() {
   printf "CREATE KEYSPACE IF NOT EXISTS %s WITH replication = {'class': 'NetworkTopologyStrategy', 'warehouse': %s, 'trino': %s};\n" \
      "${KEYSPACE}" "${KS_RF}" "${KS_RF_TRINO}"
}

# Drop the table so CREATE is not a silent no-op on an old schema (matches createTable.sh dropTbl).
dropTbl() {
   printf "DROP TABLE IF EXISTS %s.%s;\n" "${KEYSPACE}" "${TBL_NAME}"
}

# c1 uuid partition key, c2 int year DESC, c3 timeuuid ASC, c4..cN text.
createTbl() {
   local columns=("c1 uuid" "c2 int" "c3 timeuuid")
   local i

   for ((i=4; i<=TBL_COLS; i++)); do
      columns+=("c${i} text")
   done

   printf "CREATE TABLE IF NOT EXISTS %s.%s ( %s, PRIMARY KEY ((c1), c2, c3) ) WITH CLUSTERING ORDER BY (c2 DESC, c3 ASC);\n" \
      "${KEYSPACE}" "${TBL_NAME}" "$(join_by ", " "${columns[@]}")"
}

# Print `count` version-1 timeuuids inside `year`, oldest first.
# Cassandra orders timeuuid by the embedded timestamp, so this list is the ASC order.
timeuuidsForYear() {
   local year="$1"
   local count="$2"

   python3 - "$year" "$count" <<'PY'
import datetime, random, sys

year = int(sys.argv[1])
count = int(sys.argv[2])
UUID_EPOCH = 0x01B21DD213814000

def timeuuid(dt):
    hundred_ns = int(dt.timestamp() * 10_000_000) + UUID_EPOCH
    time_low = hundred_ns & 0xFFFFFFFF
    time_mid = (hundred_ns >> 32) & 0xFFFF
    time_hi = ((hundred_ns >> 48) & 0x0FFF) | 0x1000
    clock = random.getrandbits(14) | 0x8000
    node = random.getrandbits(48)
    return f"{time_low:08x}-{time_mid:04x}-{time_hi:04x}-{clock:04x}-{node:012x}"

start = datetime.datetime(year, 1, 1, tzinfo=datetime.timezone.utc)
end = datetime.datetime(year + 1, 1, 1, tzinfo=datetime.timezone.utc)
span = (end - start) / count
for i in range(count):
    # One second in, so the first value is still inside this year.
    print(timeuuid(start + span * i + datetime.timedelta(seconds=1)))
PY
}

# Generate a UUID for one partition key. Uses uuidgen if present, else the kernel's generator.
genUuid() {
   if command -v uuidgen >/dev/null 2>&1; then
      uuidgen
   else
      cat /proc/sys/kernel/random/uuid
   fi
}

# One partition: c2 walks back from this year, and each year gets `rows` ascending timeuuids.
# c4..cN are generated separately, one random string per column.
genData() {
   local cols=()
   local vals
   local uuids=()
   local c1
   local c2
   local c3
   local year
   local i
   local r
   local data

   for ((i=1; i<=TBL_COLS; i++)); do
      cols+=("c${i}")
   done

   c1="$(genUuid)"
   for ((c2=0; c2<CLUSTERS; c2++)); do
      year=$((START_YEAR - c2))
      uuids=()
      while IFS= read -r c3; do
         uuids+=("${c3}")
      done < <(timeuuidsForYear "${year}" "${ROWS}") || return 1
      [ "${#uuids[@]}" -eq "${ROWS}" ] || return 1
      for ((r=0; r<ROWS; r++)); do
         vals=("${c1}" "${year}" "${uuids[r]}")
         for ((i=4; i<=TBL_COLS; i++)); do
            data="$(genRandomStr 15)"
            vals+=("'${data}'")
         done
         printf "INSERT INTO %s.%s ( %s ) VALUES ( %s );\n" \
            "${KEYSPACE}" "${TBL_NAME}" \
            "$(join_by ", " "${cols[@]}")" \
            "$(join_by ", " "${vals[@]}")"
      done
   done
}

# Main: keyspace, drop, create, then one partition per iteration.
main() {
   local i

   createKeyspace
   dropTbl
   createTbl

   for ((i=1; i<=PARTITIONS; i++)); do
      genData || return 1
   done
}

validate_args
main > "${CQL_FILE}" || exit 1

if [ "${CREATE_TABLE_VERBOSE:-0}" = "1" ]; then
   cat "${CQL_FILE}"
fi

# cql.sh -f runs each ';'-separated statement via cql-krb.py.
if "${CQL_SH}" -f "${CQL_FILE}"; then
   echo "createCassandraTable: OK (${KEYSPACE}.${TBL_NAME}, $((PARTITIONS * CLUSTERS * ROWS)) rows, $((CLUSTERS * ROWS)) per partition)"
   exit 0
fi

echo "createCassandraTable: FAILED (${KEYSPACE}.${TBL_NAME}), CQL kept at ${CQL_FILE}" >&2
exit 1
