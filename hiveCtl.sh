#!/bin/bash
# Usage Notice: This project is not meant for commercial use without permission and proper credit.
# Author: j.martinez.poblete@gmail.com
#
# This script should live at the root of the project
# Assumptions:
# * K8S cluster is available
# * User has permissions to create/delete:
#   + StatefulSets
#   + Services
#   + ConfigMaps
#   + PersistentVolumes
#   + Pods
#
#
# Variables
#
set -o pipefail
HIVECTL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIVECTL_BIN_DIR="${HIVECTL_BIN_DIR:-${HIVECTL_ROOT}/.bin}"
PATH="${HIVECTL_BIN_DIR}:${PATH}"
HIVECTL_LOCAL_PATH_STORAGE_URL="${HIVECTL_LOCAL_PATH_STORAGE_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml}"
HIVECTL_KUSTOMIZE_INSTALL_URL="${HIVECTL_KUSTOMIZE_INSTALL_URL:-https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh}"
HIVE_STORAGE_CLASS_NAME="${HIVE_STORAGE_CLASS_NAME:-hive-on-k8s-local-path}"
#
# Helpers
#
# Print command usage and supported actions.
function help(){
   echo "Usage:  hiveCtl [available|start|stop|status|restart|backup|restore|cleanup|disk|resync-keytabs] <overlay> [<component>]"
   echo "        hiveCtl available"
   echo "        hiveCtl start   <overlay>"
   echo "        hiveCtl stop    <overlay>"
   echo "        hiveCtl restart <overlay>"
   echo "        hiveCtl restart <overlay> <component>"
   echo "        hiveCtl start   <overlay> <component>"
   echo "        hiveCtl stop    <overlay> <component>"
   echo "        hiveCtl backup  <overlay> [<backup-dir>]"
   echo "        hiveCtl restore <overlay> <backup-dir>"
   echo "  secure backup also writes mysql-ranger.sql when Ranger Admin has been started (policy DB)."
   echo "        hiveCtl cleanup <overlay>"
   echo "        hiveCtl disk   (delete HDFS query logs, then prune container images if /var is low)"
   echo "        hiveCtl resync-keytabs <overlay>   (secure: refresh Secret kerberos-keytabs from KDC PVC)"
   echo "        hiveCtl list passwd [<overlay>]    (password aliases; with overlay, keys present in hive-credentials)"
   echo "        hiveCtl get passwd <overlay> <alias>   (print one password from hive-credentials)"
   echo "        hiveCtl get passwd <alias>             (same; overlay defaults to secure, or HIVECTL_PASSWD_OVERLAY)"
   echo "        hiveCtl status   (active components, ready/total pod counts, web UI NodePort when exposed)"
   echo ""
   echo "Hue (standalone|mini|llap|secure|warehouse): port-forward (standalone=8885, mini=8886, llap=8887, secure=8888, warehouse=8889)"
   echo "  (kubectl port-forward in background unless the port already works, e.g. kind/llap-cluster.yaml)"
   echo "  While hue-0 is Ready, a background monitor restarts port-forward every minute if localhost stops responding"
   echo "  Disable forward: HIVECTL_HUE_PORT_FORWARD=0   Override port: HIVECTL_HUE_LOCAL_PORT=<port>"
   echo "  Disable monitor: HIVECTL_HUE_PORT_FORWARD_MONITOR=0   Interval: HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL=60"
   echo "Ranger Admin (secure): after 'start secure ranger', hiveCtl tries http://localhost:6080/login.jsp"
   echo "  Same port-forward + monitor pattern as Hue. Disable: HIVECTL_RANGER_PORT_FORWARD=0"
   echo "  Port: HIVECTL_RANGER_LOCAL_PORT=6080   Monitor: HIVECTL_RANGER_PORT_FORWARD_MONITOR=0"
   echo "  Login: admin + password from: kubectl get secret hive-credentials -n secure -o jsonpath='{.data.ranger-admin-password}' | base64 -d; echo"
   echo "LLAP daemon UI: http://localhost:15002 after start llapdaemon (pod llapdaemon-0)"
   echo "  Disable: HIVECTL_LLAP_DAEMON_PORT_FORWARD=0   Port: HIVECTL_LLAP_DAEMON_LOCAL_PORT=15002"
   echo "HiveServer2 (standalone|mini|llap|secure|warehouse): port-forward thrift/http/webui (base+0/+1/+2):"
   echo "  standalone 11000-11002 · mini 11100-11102 · llap 11200-11202 · secure 11300-11302 · warehouse 11400-11402"
   echo "  Disable: HIVECTL_HS2_PORT_FORWARD=0   Override bases: HIVECTL_HS2_LOCAL_PORT_BASE=<port>"
   echo "Profile secure: llap-shaped Hive (2 HMS, 2 HS2, 2 LLAP) + KDC, NN + 3 DNs, ZK, Hue (./hiveCtl.sh start secure)"
   echo "Ranger (secure, optional): HIVECTL_SECURE_RANGER=1 ./hiveCtl.sh start secure   or: ./hiveCtl.sh start secure ranger"
   echo "  NodePort 30680. Browser URL: HIVECTL_RANGER_EXTERNAL_URL (default http://127.0.0.1:6080)"
   echo "  Ranger Admin image: jpoblete73/ranger:2.4.0 (arm64 + amd64). Override: RANGER_ADMIN_IMAGE=<image>"
   echo "Ranger Hive plugin (secure HS2 Phase 2): build docker/hive-ranger, then HIVECTL_SECURE_RANGER_HS2=1 ./hiveCtl.sh start secure hiveserver2"
   echo "  With HS2 plugin, hiveCtl creates secure_hive + lab admin policies (HIVECTL_SECURE_RANGER_BOOTSTRAP_HIVE=auto; 0 to skip)"
   echo "  Image: HIVE_RANGER_IMAGE=hive-on-k8s/hive-ranger:2.4.0-nightly (default)"
   echo "  Kind: hiveCtl runs 'kind load docker-image' for that tag when present locally (HIVECTL_KIND_LOAD=0 to skip)"
   echo "  Kind cluster name: HIVECTL_KIND_CLUSTER_NAME or KIND_CLUSTER (else inferred from node name, e.g. desktop)"
   echo "Hive SYS schema: after HiveServer2 is Ready, hiveCtl runs schematool -initSchema -dbType hive once on one HS2 pod"
   echo "  (standalone: hive-0 container hiveserver2). JDBC URL is that pod's BEELINE_URL. metaDbType mysql (mini|llap|secure) or derby (standalone)."
   echo "  Skips when database sys already exists. Disable: HIVECTL_HIVE_SYS_SCHEMA=0"
   echo "  Retries: HIVECTL_HIVE_SYS_SCHEMA_ATTEMPTS=6  HIVECTL_HIVE_SYS_SCHEMA_RETRY_SEC=10"
   echo "Disk: before start/restore, hiveCtl checks Kind /var on all nodes (mini, llap, secure, standalone)"
   echo "  Prune when use exceeds threshold: HIVECTL_DISK_MAX_USE_PERCENT=90 (HIVECTL_DISK_CHECK=0 to skip)"
   echo "Storage: before start/restore, hiveCtl requires StorageClass ${HIVE_STORAGE_CLASS_NAME} (rancher.io/local-path, Retain)"
   echo "  Installs ${HIVECTL_LOCAL_PATH_STORAGE_URL} when missing (HIVECTL_STORAGE_CHECK=0 to skip)"
   echo "  Override class name: HIVE_STORAGE_CLASS_NAME=<name>"
   echo "Host tools: kubectl (required); kustomize auto-installed to ${HIVECTL_BIN_DIR} when missing (HIVECTL_KUSTOMIZE_INSTALL=0 to disable)"
   echo "  Pin version: HIVECTL_KUSTOMIZE_VERSION=5.4.3   Install URL: HIVECTL_KUSTOMIZE_INSTALL_URL"
}
# Print the names of the objects kubectl get selects, nothing when there are none.
# A failed API call isn't read as "none": after three attempts its error is shown and the status is 2.
function kubectlNames(){
   local attempt=1
   local errors=""

   until errors="$(kubectl get "$@" -o name --ignore-not-found 2>&1 >&3)"; do
      if [ "${attempt}" -ge 3 ]; then
         echo "${errors}" >&2
         return 2
      fi
      attempt=$((attempt + 1))
      sleep 2
   done 3>&1
}
# Return 0 when the Kubernetes namespace exists, 1 when it doesn't, 2 when Kubernetes can't be queried.
function namespaceExists(){
   local namespace="$1"
   local names=""

   names="$(kubectlNames namespace "${namespace}")" || return 2
   [ -n "${names}" ]
}
# Require a namespace before running namespace-scoped operations.
function requireNamespace(){
   local namespace="$1"

   namespaceExists "${namespace}"
   case $? in
      0) return 0 ;;
      1) echo "Namespace '${namespace}' does not exist" ;;
   esac
   return 1
}
# Create the namespace when it doesn't exist yet.
function ensureNamespace(){
   local namespace="$1"

   namespaceExists "${namespace}"
   case $? in
      0) return 0 ;;
      1) kubectl create namespace "${namespace}" --save-config >/dev/null ;;
      *) return 1 ;;
   esac
}
# Generate a local password for Kubernetes Secrets.
function generatePassword(){
   if command -v uuidgen >/dev/null 2>&1; then
      uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'
   else
      date "+%s%N"
   fi
}
# Ranger UI/DB passwords must include upper, lower, and digit (see setup.sh validatePassword).
function generateRangerPassword(){
   local suffix=""
   suffix="$(generatePassword)"
   printf 'Ra%s' "${suffix:0:29}"
}
function rangerPasswordMeetsPolicy(){
   local password="$1"
   [ "${#password}" -ge 8 ] || return 1
   [[ "${password}" =~ [A-Z] ]] || return 1
   [[ "${password}" =~ [a-z] ]] || return 1
   [[ "${password}" =~ [0-9] ]] || return 1
   case "${password}" in *[\`\'\"]* ) return 1 ;; esac
   return 0
}
# Create the namespace-local Secret used by bootstrap scripts when absent.
function ensureSecrets(){
   local namespace="$1"
   local root_password=""
   local hive_password=""
   local hadoop_password=""
   local mysql_root_password=""
   local hive_metastore_password=""
   local beeline_password=""
   local hue_mysql_password=""
   local hue_secret_key=""
   local hue_admin_password=""
   local admin_password=""
   local krb5_master_password=""
   local krb5_kadmin_password=""
   local names=""

   ensureNamespace "${namespace}" || return 1
   names="$(kubectlNames secret hive-credentials -n "${namespace}")" || return 1
   if [ -n "${names}" ]; then
      return 0
   fi

   root_password="$(generatePassword)"
   hive_password="$(generatePassword)"
   hadoop_password="$(generatePassword)"
   mysql_root_password="$(generatePassword)"
   hive_metastore_password="$(generatePassword)"
   beeline_password="${hive_password}"
   hue_mysql_password="$(generatePassword)"
   hue_secret_key="$(generatePassword)"
   admin_password="admin"
   hue_admin_password="$(generatePassword)"
   krb5_master_password="$(generatePassword)"
   krb5_kadmin_password="$(generatePassword)"

   # Existing mini PVCs were initialized with the historical lab passwords.
   # Preserve compatibility so adding Secrets does not break a running metastore.
   if [ "${namespace}" = "mini" ]; then
      names="$(kubectlNames pvc mysql-mysql-0 -n "${namespace}")" || return 1
      if [ -n "${names}" ]; then
         root_password="cloudera"
         hive_password="hive"
         hadoop_password="hadoop"
         mysql_root_password="mysql"
         hive_metastore_password="hive"
         beeline_password="hive"
      fi
   fi

   if [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ]; then
      kubectl create secret generic hive-credentials -n "${namespace}" \
         --from-literal=root-password="${root_password}" \
         --from-literal=hive-password="${hive_password}" \
         --from-literal=hadoop-password="${hadoop_password}" \
         --from-literal=mysql-root-password="${mysql_root_password}" \
         --from-literal=hive-metastore-password="${hive_metastore_password}" \
         --from-literal=beeline-password="${beeline_password}" \
         --from-literal=hue-mysql-password="${hue_mysql_password}" \
         --from-literal=hue-secret-key="${hue_secret_key}" \
         --from-literal=hue-admin-password="${hue_admin_password}" \
         --from-literal=admin-password="${admin_password}" \
         --from-literal=krb5-master-password="${krb5_master_password}" \
         --from-literal=krb5-kadmin-password="${krb5_kadmin_password}" >/dev/null
   else
      kubectl create secret generic hive-credentials -n "${namespace}" \
         --from-literal=root-password="${root_password}" \
         --from-literal=hive-password="${hive_password}" \
         --from-literal=hadoop-password="${hadoop_password}" \
         --from-literal=mysql-root-password="${mysql_root_password}" \
         --from-literal=hive-metastore-password="${hive_metastore_password}" \
         --from-literal=beeline-password="${beeline_password}" \
         --from-literal=hue-mysql-password="${hue_mysql_password}" \
         --from-literal=hue-secret-key="${hue_secret_key}" \
         --from-literal=hue-admin-password="${hue_admin_password}" \
         --from-literal=admin-password="${admin_password}" >/dev/null
   fi
}
# Add MIT KDC credentials to an existing secure secret (clusters created before krb5kdc).
function ensureKrb5Secrets(){
   local namespace="$1"
   local krb5_master_password=""
   local krb5_kadmin_password=""
   local existing=""

   case "${namespace}" in secure|warehouse) ;; *) return 0 ;; esac
   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.krb5-master-password}' 2>/dev/null)" || return 1
   if [ -n "${existing}" ]; then
      return 0
   fi
   krb5_master_password="$(generatePassword)"
   krb5_kadmin_password="$(generatePassword)"
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p "{\"stringData\":{\"krb5-master-password\":\"${krb5_master_password}\",\"krb5-kadmin-password\":\"${krb5_kadmin_password}\"}}" >/dev/null
}
# Wait until the KDC pod has written lab keytabs to its PVC.
function waitForLabKeytabs(){
   local namespace="$1"
   local attempt=0

   while [ "${attempt}" -lt 60 ]; do
      if kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-keytabs-hadoop-hive-admin 2>/dev/null; then
         return 0
      fi
      attempt=$((attempt + 1))
      sleep 5
   done
   echo "Timed out waiting for lab keytabs on krb5kdc in namespace '${namespace}'"
   return 1
}
# Warehouse database passwords for the Trino catalogs (MySQL, Postgres, Oracle) and the database admins.
function ensureWarehouseDatabaseSecrets(){
   local namespace="$1"
   local key=""
   local patch=""

   [ "${namespace}" = "warehouse" ] || return 0
   ensureSecrets "${namespace}" || return 1
   for key in mysql-trino-password postgres-password postgres-trino-password oracle-password oracle-trino-password; do
      if [ -z "$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath="{.data.${key}}" 2>/dev/null)" ]; then
         # Oracle requires upper case, lower case, and a digit.
         patch="${patch:+${patch},}\"${key}\":\"$(generateRangerPassword)\""
      fi
   done
   [ -n "${patch}" ] || return 0
   kubectl patch secret hive-credentials -n "${namespace}" --type merge -p "{\"stringData\":{${patch}}}" >/dev/null
}
# Apply the bigdata schema and trino user for a warehouse Trino database (idempotent).
function applyWarehouseDatabaseSchema(){
   local namespace="$1"
   local service="$2"
   local script="./components/${service}/setup/apply-bigdata-schema.sh"

   [ "${namespace}" = "warehouse" ] && [ -f "${script}" ] || return 0
   echo "Applying ${service} bigdata schema and trino user ..."
   NS="${namespace}" POD="${service}-0" bash "${script}"
}
# trino Cassandra DC (docs/cassandra-trino-two-dc-design.md): internal CA, server and Trino client
# certificates, and the Trino role password. Existing Secrets are kept.
function ensureCassandraTrinoSecrets(){
   local namespace="$1"
   local realm=""
   local tmpdir=""
   local pod="cassandra-trino-tls-gen"
   local server_ks_pw=""
   local server_ts_pw=""
   local client_ks_pw=""
   local client_ts_pw=""
   local domain="${namespace}.svc.cluster.local"

   if kubectl get secret cassandra-trino-tls trino-cassandra-tls trino-cassandra-client-tls cassandra-trino-role \
      -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi
   if ! command -v openssl >/dev/null 2>&1; then
      echo "openssl is required to create the cassandra-trino certificates"
      return 1
   fi
   echo "Provisioning cassandra-trino certificates and Trino role Secrets ..."
   realm="$(echo "${namespace}" | tr '[:lower:]' '[:upper:]').LAB"
   server_ks_pw="$(generatePassword)"
   server_ts_pw="$(generatePassword)"
   client_ks_pw="$(generatePassword)"
   client_ts_pw="$(generatePassword)"
   tmpdir="$(mktemp -d)"
   trap 'rm -rf "${tmpdir}"' RETURN
   (
      cd "${tmpdir}" || exit 1
      openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 3650 -subj "/CN=${namespace}-internal-ca" 2>/dev/null &&
      openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=cassandra-trino" 2>/dev/null &&
      printf 'subjectAltName=DNS:cassandra-trino,DNS:cassandra-trino-headless.%s,DNS:cassandra-trino-0.cassandra-trino-headless.%s\n' \
         "${domain}" "${domain}" > server.ext &&
      openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -extfile server.ext 2>/dev/null &&
      openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN=trino-client" 2>/dev/null &&
      openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 825 2>/dev/null &&
      openssl pkcs12 -export -in server.crt -inkey server.key -name cassandra-trino -out server.p12 -passout "pass:${server_ks_pw}" &&
      openssl pkcs12 -export -in client.crt -inkey client.key -name trino-client -out client.p12 -passout "pass:${client_ks_pw}"
   ) || return 1

   # Java keystores are built with the keytool of the Cassandra image.
   kubectl run "${pod}" -n "${namespace}" --image=jpoblete73/cassandra-kerberos:4.1.12 --restart=Never \
      --command -- sleep 600 >/dev/null || return 1
   kubectl wait --for=condition=Ready "pod/${pod}" -n "${namespace}" --timeout=300s >/dev/null || return 1
   local file=""
   for file in ca.crt server.p12 client.p12; do
      kubectl cp "${tmpdir}/${file}" "${namespace}/${pod}:/tmp/${file}" >/dev/null || return 1
   done
   # shellcheck disable=SC2016
   kubectl exec "${pod}" -n "${namespace}" -- env SKP="${server_ks_pw}" STP="${server_ts_pw}" CKP="${client_ks_pw}" CTP="${client_ts_pw}" sh -c '
      cd /tmp &&
      keytool -importkeystore -noprompt -srckeystore server.p12 -srcstoretype PKCS12 -srcstorepass "$SKP" -destkeystore server-keystore.jks -deststoretype JKS -deststorepass "$SKP" >/dev/null 2>&1 &&
      keytool -importcert -noprompt -alias ca -file ca.crt -keystore server-truststore.jks -storetype JKS -storepass "$STP" >/dev/null 2>&1 &&
      keytool -importkeystore -noprompt -srckeystore client.p12 -srcstoretype PKCS12 -srcstorepass "$CKP" -destkeystore client-keystore.jks -deststoretype JKS -deststorepass "$CKP" >/dev/null 2>&1 &&
      keytool -importcert -noprompt -alias ca -file ca.crt -keystore client-truststore.jks -storetype JKS -storepass "$CTP" >/dev/null 2>&1' || return 1
   for file in server-keystore.jks server-truststore.jks client-keystore.jks client-truststore.jks; do
      kubectl cp "${namespace}/${pod}:/tmp/${file}" "${tmpdir}/${file}" >/dev/null || return 1
   done
   kubectl delete pod "${pod}" -n "${namespace}" --now >/dev/null

   kubectl create secret generic cassandra-trino-tls -n "${namespace}" \
      --from-file=keystore.jks="${tmpdir}/server-keystore.jks" --from-literal=keystore.password="${server_ks_pw}" \
      --from-file=truststore.jks="${tmpdir}/server-truststore.jks" --from-literal=truststore.password="${server_ts_pw}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
   kubectl create secret generic trino-cassandra-tls -n "${namespace}" \
      --from-file=keystore.jks="${tmpdir}/client-keystore.jks" --from-literal=keystore.password="${client_ks_pw}" \
      --from-file=truststore.jks="${tmpdir}/client-truststore.jks" --from-literal=truststore.password="${client_ts_pw}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
   kubectl create secret generic trino-cassandra-client-tls -n "${namespace}" \
      --from-file=ca.crt="${tmpdir}/ca.crt" --from-file=client.crt="${tmpdir}/client.crt" --from-file=client.key="${tmpdir}/client.key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
   if ! kubectl get secret cassandra-trino-role -n "${namespace}" >/dev/null 2>&1; then
      kubectl create secret generic cassandra-trino-role -n "${namespace}" \
         --from-literal=username="trino@${realm}" --from-literal=password="$(generatePassword)" >/dev/null || return 1
   fi
}
# Add the trino DC to every replicated keyspace, stream existing data, then create the
# Trino superuser role. Idempotent.
# Replication is changed over GSSAPI on cassandra-0: that node's role manager rejects
# PASSWORD. The role itself is created on cassandra-trino, whose PasswordAuthenticator
# accepts it. Password login reads system_auth at LOCAL_QUORUM, so the rebuild has to
# finish first or the trino DC has no local replica to read.
function ensureCassandraTrinoRole(){
   local namespace="$1"
   local result=""

   secret_value(){ kubectl get secret "$1" -n "${namespace}" -o jsonpath="{.data.${2//./\\.}}" | base64 -d; }
   # shellcheck disable=SC2016
   result="$(kubectl exec -i cassandra-0 -n "${namespace}" -c cassandra -- python3 - <<'PY'
import socket, sys, time
from cassandra import ConsistencyLevel
from cassandra.auth import AuthProvider, SaslAuthenticator
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT

class FqdnGssapiProvider(AuthProvider):
    def new_authenticator(self, host):
        return SaslAuthenticator(socket.getfqdn(host), "cassandra", mechanism="GSSAPI", qop="auth")

profile = ExecutionProfile(consistency_level=ConsistencyLevel.LOCAL_ONE)
contact = socket.getfqdn("cassandra-0.cassandra-headless")
last = None
for attempt in range(12):
    try:
        cluster = Cluster([contact], port=9042, auth_provider=FqdnGssapiProvider(),
                          execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                          connect_timeout=30, control_connection_timeout=30)
        s = cluster.connect()
        altered = False
        for ks, repl in s.execute("SELECT keyspace_name, replication FROM system_schema.keyspaces"):
            cls = repl.get("class", "")
            if cls.endswith("LocalStrategy") or cls.endswith("EverywhereStrategy") or "trino" in repl:
                continue
            new = {k: v for k, v in repl.items() if k != "class"}
            if cls.endswith("SimpleStrategy"):
                new = {"warehouse": new.pop("replication_factor", "3")}
            new["trino"] = "1"
            s.execute('ALTER KEYSPACE "%s" WITH replication = %s' % (ks, {"class": "NetworkTopologyStrategy", **new}))
            altered = True
        print("REBUILD" if altered else "OK")
        cluster.shutdown()
        break
    except Exception as exc:
        last = exc
        time.sleep(10)
else:
    print("cannot add the trino DC to keyspaces via cassandra-0: %s" % last, file=sys.stderr)
    raise SystemExit(1)
PY
)" || return 1
   if [ "${result##*$'\n'}" = "REBUILD" ]; then
      echo "Streaming existing Cassandra data into the trino DC (nodetool rebuild) ..."
      kubectl exec cassandra-trino-0 -n "${namespace}" -c cassandra -- nodetool rebuild -- warehouse || return 1
   fi
   # shellcheck disable=SC2016
   kubectl exec -i cassandra-trino-0 -n "${namespace}" -c cassandra -- \
      env CA="$(secret_value trino-cassandra-client-tls ca.crt)" CRT="$(secret_value trino-cassandra-client-tls client.crt)" \
          KEY="$(secret_value trino-cassandra-client-tls client.key)" \
          ROLE="$(secret_value cassandra-trino-role username)" ROLE_PW="$(secret_value cassandra-trino-role password)" \
      python3 - <<'PY' || return 1
import os, socket, ssl, sys, tempfile, time
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster

d = tempfile.mkdtemp()
for name in ("CA", "CRT", "KEY"):
    with open(os.path.join(d, name), "w") as fh:
        fh.write(os.environ[name])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.load_verify_locations(os.path.join(d, "CA"))
ctx.load_cert_chain(os.path.join(d, "CRT"), os.path.join(d, "KEY"))
host = socket.gethostbyname(socket.gethostname())
role, role_pw = os.environ["ROLE"], os.environ["ROLE_PW"]

def connect(user, password):
    return Cluster([host], ssl_context=ctx, auth_provider=PlainTextAuthProvider(user, password),
                   connect_timeout=30, control_connection_timeout=30).connect()

last = None
for attempt in range(12):
    try:
        try:
            s = connect(role, role_pw)
            # A role cannot change its own superuser flag. CREATE already set it.
            s.execute("ALTER ROLE %s WITH LOGIN = true AND PASSWORD = %s", (role, role_pw))
        except Exception:
            s = connect("cassandra", "cassandra")
            s.execute("CREATE ROLE IF NOT EXISTS %s WITH SUPERUSER = true AND LOGIN = true AND PASSWORD = %s", (role, role_pw))
            s.execute("ALTER ROLE %s WITH LOGIN = true AND PASSWORD = %s", (role, role_pw))
        s.cluster.shutdown()
        break
    except Exception as exc:
        last = exc
        time.sleep(10)
else:
    print("cannot create the trino role on cassandra-trino: %s" % last, file=sys.stderr)
    raise SystemExit(1)
PY
   echo "Cassandra trino DC ready (role $(secret_value cassandra-trino-role username))"
}
# Copy lab keytabs from the KDC PVC into Secret kerberos-keytabs for pod mounts.
function ensureKerberosKeytabSecret(){
   local namespace="$1"
   local tmpdir=""
   local keytab_list=""
   local keytab_file=""
   local create_args=()

   case "${namespace}" in secure|warehouse) ;; *) return 0 ;; esac
   if kubectl get secret kerberos-keytabs -n "${namespace}" >/dev/null 2>&1; then
      if [ -n "$(kubectl get secret kerberos-keytabs -n "${namespace}" -o jsonpath='{.data.hadoop-namenode-0\.keytab}' 2>/dev/null)" ] \
         && [ -z "${HIVECTL_KRB5_RESYNC_KEYTABS:-}" ]; then
         return 0
      fi
   fi
   waitForReady "${namespace}" "krb5kdc" || return 1
   waitForLabKeytabs "${namespace}" || return 1
   if ! kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-host-keytabs-v3 2>/dev/null; then
      echo "Waiting for host keytabs on krb5kdc (.lab-host-keytabs-v3) ..."
      local attempt=0
      while [ "${attempt}" -lt 60 ]; do
         if kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-host-keytabs-v3 2>/dev/null; then
            break
         fi
         attempt=$((attempt + 1))
         sleep 5
      done
      kubectl exec -n "${namespace}" krb5kdc-0 -- test -f /var/lib/krb5kdc/keytabs/.lab-host-keytabs-v3 2>/dev/null || return 1
   fi
   tmpdir="$(mktemp -d)"
   trap 'rm -rf "${tmpdir}"' RETURN
   keytab_list="$(kubectl exec -n "${namespace}" krb5kdc-0 -- sh -c 'ls -1 /var/lib/krb5kdc/keytabs/*.keytab' 2>/dev/null)" || return 1
   for keytab_file in ${keytab_list}; do
      kubectl exec -n "${namespace}" krb5kdc-0 -- cat "${keytab_file}" > "${tmpdir}/$(basename "${keytab_file}")" || return 1
      create_args+=(--from-file="$(basename "${keytab_file}")=${tmpdir}/$(basename "${keytab_file}")")
   done
   kubectl create secret generic kerberos-keytabs -n "${namespace}" \
      "${create_args[@]}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
}
# Impala principals: per-pod impala/<pod fqdn> from the host list (added to a KDC provisioned
# before Impala existed), plus the shared client-facing impala/impala.<ns>.svc.cluster.local in
# every impalad keytab so clients can reach any coordinator through Service impala. The shared
# key is exported with -norandkey; a plain ktadd would re-key it and invalidate the other keytabs.
function ensureImpalaKeytabs(){
   local namespace="$1"
   local attempt=0
   local realm=""
   local svc_principal=""
   local keytab_dir="/var/lib/krb5kdc/keytabs"
   local i=""

   realm="$(echo "${namespace}" | tr '[:lower:]' '[:upper:]').LAB"
   svc_principal="impala/impala.${namespace}.svc.cluster.local@${realm}"
   waitForReady "${namespace}" "krb5kdc" || return 1
   if kubectl exec -n "${namespace}" krb5kdc-0 -- sh -c "for i in 0 1 2; do klist -kt ${keytab_dir}/impalad-\$i.keytab 2>/dev/null | grep -q '${svc_principal}' || exit 1; done" \
      && [ -n "$(kubectl get secret kerberos-keytabs -n "${namespace}" -o jsonpath='{.data.impalad-0\.keytab}' 2>/dev/null)" ]; then
      return 0
   fi
   if ! kubectl exec -n "${namespace}" krb5kdc-0 -- test -f "${keytab_dir}/impalad-0.keytab" 2>/dev/null; then
      echo "Adding Impala principals to the ${namespace} KDC ..."
      applyOverlayKustomize "./overlays/${namespace}/krb5kdc/" >/dev/null || return 1
      waitForReady "${namespace}" "krb5kdc" || return 1
      until kubectl exec -n "${namespace}" krb5kdc-0 -- grep -q '|impalad-0$' /config/secure-lab-hosts.list 2>/dev/null; do
         attempt=$((attempt + 1))
         if [ "${attempt}" -ge 60 ]; then
            echo "krb5kdc-0 did not pick up the Impala hosts in /config/secure-lab-hosts.list"
            return 1
         fi
         sleep 5
      done
      kubectl exec -n "${namespace}" krb5kdc-0 -- env KRB5_REALM="${realm}" \
         bash /config/provision-host-keytabs.sh >/dev/null || return 1
   fi
   echo "Adding ${svc_principal} to the impalad keytabs ..."
   kubectl exec -n "${namespace}" krb5kdc-0 -- kadmin.local -q "addprinc -randkey ${svc_principal}" >/dev/null 2>&1 || true
   for i in 0 1 2; do
      kubectl exec -n "${namespace}" krb5kdc-0 -- kadmin.local -q "ktadd -norandkey -k ${keytab_dir}/impalad-${i}.keytab ${svc_principal}" >/dev/null || return 1
   done
   HIVECTL_KRB5_RESYNC_KEYTABS=1 ensureKerberosKeytabSecret "${namespace}"
}
# Add admin-password to an existing secret (clusters created before the admin OS user).
function ensureAdminSecrets(){
   local namespace="$1"
   local admin_password=""
   local existing=""

   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.admin-password}' 2>/dev/null)" || return 1
   if [ -n "${existing}" ]; then
      return 0
   fi
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p '{"stringData":{"admin-password":"admin"}}' >/dev/null
}
# Add Hue credentials to an existing llap secret (for clusters created before Hue).
function ensureHueSecrets(){
   local namespace="$1"
   local hue_mysql_password=""
   local hue_secret_key=""
   local existing=""

   case "${namespace}" in standalone|mini|llap|secure|warehouse) ;; *) return 0 ;; esac
   ensureSecrets "${namespace}" || return 1
   # Hue's init container sets the Django admin login to this value on every start.
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.hue-admin-password}' 2>/dev/null)" || return 1
   if [ -z "${existing}" ]; then
      kubectl patch secret hive-credentials -n "${namespace}" --type merge \
         -p "{\"stringData\":{\"hue-admin-password\":\"$(generatePassword)\"}}" >/dev/null || return 1
   fi
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.hue-mysql-password}' 2>/dev/null)" || return 1
   if [ -n "${existing}" ]; then
      return 0
   fi
   hue_mysql_password="$(generatePassword)"
   hue_secret_key="$(generatePassword)"
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p "{\"stringData\":{\"hue-mysql-password\":\"${hue_mysql_password}\",\"hue-secret-key\":\"${hue_secret_key}\"}}" >/dev/null
}
# Ranger Admin DB + UI passwords (secure profile, opt-in component).
function ensureRangerSecrets(){
   local namespace="$1"
   local ranger_db_password=""
   local ranger_admin_password=""
   local existing=""

   [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ] || return 0
   ensureSecrets "${namespace}" || return 1
   existing="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.ranger-db-password}' 2>/dev/null)" || return 1
   if [ -z "${existing}" ]; then
      ranger_db_password="$(generatePassword)"
      ranger_admin_password="$(generateRangerPassword)"
      kubectl patch secret hive-credentials -n "${namespace}" --type merge \
         -p "{\"stringData\":{\"ranger-db-password\":\"${ranger_db_password}\",\"ranger-admin-password\":\"${ranger_admin_password}\"}}" >/dev/null
      return 0
   fi
   ranger_admin_password="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.ranger-admin-password}' 2>/dev/null | base64 -d 2>/dev/null)"
   if rangerPasswordMeetsPolicy "${ranger_admin_password}"; then
      return 0
   fi
   ranger_admin_password="$(generateRangerPassword)"
   echo "Updating ranger-admin-password in hive-credentials (Ranger requires upper+lower+digit)."
   kubectl patch secret hive-credentials -n "${namespace}" --type merge \
      -p "{\"stringData\":{\"ranger-admin-password\":\"${ranger_admin_password}\"}}" >/dev/null
}
# Drop Ranger schema and allow setup.sh to run again (HIVECTL_RANGER_REINIT=1).
function reinitRangerDatabase(){
   local namespace="$1"

   [ "${namespace}" = "secure" ] || return 0
   if ! kubectl get svc mysql -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi
   echo "Reinitializing Ranger MySQL database (HIVECTL_RANGER_REINIT=1) ..."
   kubectl exec -n "${namespace}" mysql-0 -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS ranger; CREATE DATABASE ranger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"' || return 1
   if kubectl get pod ranger-0 -n "${namespace}" >/dev/null 2>&1; then
      kubectl exec -n "${namespace}" ranger-0 -c ranger -- rm -f /opt/ranger/.setupDone 2>/dev/null || true
   fi
}
# Wait for ranger-mysql-init Job after first apply.
function waitForRangerMysqlInit(){
   local namespace="$1"

   [ "${namespace}" = "secure" ] || return 0
   if ! kubectl get job ranger-mysql-init -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi
   kubectl wait --for=condition=complete job/ranger-mysql-init -n "${namespace}" --timeout=300s
}
# Restore namespace credentials from a backup when present. MySQL creates its users on first boot and
# the metastore dump doesn't include them, so once MySQL has a volume the current credentials are kept.
function restoreSecrets(){
   local namespace="$1"
   local backup_dir="$2"
   local secret_file="${backup_dir}/hive-credentials.secret.json"
   local names=""

   if [ ! -f "${secret_file}" ]; then
      ensureSecrets "${namespace}"
      return $?
   fi
   ensureNamespace "${namespace}" || return 1
   names="$(kubectlNames pvc mysql-mysql-0 -n "${namespace}")" || return 1
   if [ -n "${names}" ]; then
      ensureSecrets "${namespace}" || return 1
      if ! kubectl get secret hive-credentials -n "${namespace}" -o json \
         | python3 -c 'import json, sys; sys.exit(json.load(sys.stdin)["data"] != json.load(open(sys.argv[1]))["data"])' "${secret_file}"; then
         echo "Keeping the current credentials of '${namespace}': its MySQL users were created with them, and the dump doesn't include users"
      fi
      return 0
   fi
   python3 -c 'import json, sys
obj = json.load(open(sys.argv[1]))
obj["metadata"].pop("namespace", None)
print(json.dumps(obj))
' "${secret_file}" | kubectl apply -n "${namespace}" -f - >/dev/null
}
# List overlay/component pairs discovered from Kustomize files.
function overlays(){
   #
   # Available Overlays
   #
   find ./overlays -name kustomization.yaml -type f -print | awk -F/ 'NF >= 4 {print $3"_"$4}' | sort
}
# First NodePort in ns whose Service targets container port want_port (9870 = NN UI, 15002 = LLAP web).
function firstServiceNodePortForTargetPort(){
   local namespace="$1"
   local want_port="$2"

   kubectl get svc -n "${namespace}" -o json 2>/dev/null \
      | python3 -c '
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)
for svc in data.get("items", []):
    for p in (svc.get("spec") or {}).get("ports") or []:
        tp = p.get("targetPort")
        if tp is None:
            continue
        if str(tp) != str(want):
            continue
        np = p.get("nodePort")
        if np:
            print(np)
            sys.exit(0)
sys.exit(1)
' "${want_port}" 2>/dev/null || true
}
# Optional NodePort for a browser-facing port (Hue, Ranger, HS2 Web UI, LLAP UI, NameNode HDFS UI).
# Empty when ClusterIP-only, headless, or the Service is missing.
function overlayWebUiNodePort(){
   local namespace="$1"
   local service="$2"
   local np=""

   case "${service}" in
      hue)
         np="$(kubectl get svc hue -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)"
         ;;
      ranger)
         np="$(kubectl get svc ranger -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)"
         ;;
      trino)
         # Trino coordinator UI (NodePort 30080, served by the coordinator; reachable via the bastion)
         np="$(kubectl get svc trino -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)"
         ;;
      hive)
         # standalone profile: Service hiveserver2 (all-in-one StatefulSet app=hive)
         np="$(kubectl get svc hiveserver2 -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="webui")].nodePort}' 2>/dev/null)"
         ;;
      hiveserver2)
         # mini|llap|secure: HS2 NodePorts are on Service hiveserver2 (renamed from hivemetastore)
         np="$(kubectl get svc hiveserver2 -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="webui")].nodePort}' 2>/dev/null)"
         ;;
      llapdaemon)
         np="$(kubectl get svc llapdaemon -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="web")].nodePort}' 2>/dev/null)"
         if [ -z "${np}" ]; then
            np="$(firstServiceNodePortForTargetPort "${namespace}" 15002)"
         fi
         ;;
      hadoop-namenode)
         # HDFS NameNode UI (9870): dedicated NodePort Service hadoop-namenode-ui (nameservice stays headless for RPC)
         np="$(kubectl get svc hadoop-namenode-ui -n "${namespace}" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)"
         if [ -z "${np}" ]; then
            np="$(firstServiceNodePortForTargetPort "${namespace}" 9870)"
         fi
         ;;
   esac
   printf '%s' "${np}"
}
# Human-readable run state for one overlay workload (StatefulSet or Deployment name = service).
function overlayComponentState(){
   local namespace="$1"
   local service="$2"
   local ready=""
   local desired=""
   local not_ready_pods=""

   # Workloads named like the component (cassandra, hue, ...) match by name. Others (e.g. trino-coordinator
   # labelled app=trino) are found by their app label.
   local sts_name="${service}"
   if ! kubectl get statefulset "${service}" -n "${namespace}" >/dev/null 2>&1; then
      sts_name="$(kubectl get statefulset -n "${namespace}" -l "app=${service}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
   fi
   if [ -n "${sts_name}" ] && kubectl get statefulset "${sts_name}" -n "${namespace}" >/dev/null 2>&1; then
      desired="$(kubectl get statefulset "${sts_name}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
      ready="$(kubectl get statefulset "${sts_name}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
   elif kubectl get deployment "${service}" -n "${namespace}" >/dev/null 2>&1; then
      desired="$(kubectl get deployment "${service}" -n "${namespace}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
      ready="$(kubectl get deployment "${service}" -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
   else
      echo "deployed (workload missing)"
      return 1
   fi

   ready="${ready:-0}"
   desired="${desired:-0}"

   if [ "${desired}" -eq 0 ]; then
      echo "stopped (0/0)"
      return 1
   fi
   if [ "${ready}" -ge "${desired}" ]; then
      echo "running (${ready}/${desired})"
      return 0
   fi

   not_ready_pods="$(kubectl get pods -n "${namespace}" -l "app=${service}" --field-selector=status.phase!=Running --no-headers 2>/dev/null \
      | awk '$3 ~ /CrashLoopBackOff|Error|Failed|ImagePullBackOff/ {print $3}' | head -1)"
   if [ -n "${not_ready_pods}" ]; then
      echo "failed (${ready}/${desired}, ${not_ready_pods})"
      return 1
   fi
   echo "not ready (${ready}/${desired})"
   return 1
}
# List overlays that currently have an active StatefulSet or Deployment.
function activeOverlays(){
   #
   # Each Overlay lives in it's own Namespace of the same name
   #
   local arg="${1:-}"
   local target=""
   local active_list=""
   local namespace=""
   local service=""
   local state=""
   local status=0

   for target in $(overlays); do
       overlayActive "${target}"
       case $? in
          0) active_list="${active_list}${target}"$'\n' ;;
          2)
             status=1
             break
             ;;
       esac
   done

   if [ -n "${arg}" ]; then
      echo "Active Overlays:"
      printf "  %-28s  %-40s  %s\n" "COMPONENT" "STATE" "WEB UI (NodePort)"
      while IFS= read -r target; do
         [ -n "${target}" ] || continue
         namespace="${target%_*}"
         service="${target#*_}"
         state="$(overlayComponentState "${namespace}" "${service}")" || true
         ui_np="$(overlayWebUiNodePort "${namespace}" "${service}")"
         if [ -z "${ui_np}" ]; then
            ui_np="-"
         fi
         printf "  %-28s  %-40s  %s\n" "${target}" "${state:-unknown}" "${ui_np}"
      done <<< "${active_list}"
      return "${status}"
   fi
   printf "%s" "${active_list}"
   return "${status}"
}
# Return success when the requested overlay exists in the project.
function overlayExists(){
   #
   # Checks whether the requested overlay exists exactly.
   #
   local target="$1"

   overlays | awk -v target="${target}" '$0 == target {found=1} END {exit !found}'
}
# Return 0 when the requested overlay has a StatefulSet, 1 when it doesn't, 2 when Kubernetes can't be queried.
function overlayActive(){
   local target="$1"
   local names=""

   local namespace="${target%_*}"
   local service="${target#*_}"

   names="$(kubectlNames statefulsets -n "${namespace}" --selector="app=${service}")" || return 2
   if [ -n "${names}" ]; then
      return 0
   fi
   names="$(kubectlNames deployments -n "${namespace}" --selector="app=${service}")" || return 2
   [ -n "${names}" ]
}
# Apply NameNode and three DataNodes together (NameNode startup waits for live DNs).
function startSecureHadoop(){
   local namespace="${1:-secure}"
   local nn_path="./overlays/${namespace}/hadoop-namenode/"
   local dn_path="./overlays/${namespace}/hadoop-datanode/"

   ensureSecrets "${namespace}" || return 1
   ensureAdminSecrets "${namespace}" || return 1
   ensureKerberosKeytabSecret "${namespace}" || return 1
   echo "Starting Overlay: ${namespace}_hadoop (namenode + 3 datanodes) ..."
   kustomize build "${nn_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f - || return 1
   kustomize build "${dn_path}" --load-restrictor LoadRestrictionsNone | kubectl apply -f - || return 1
   waitForReady "${namespace}" "hadoop-datanode" || return 1
   waitForReady "${namespace}" "hadoop-namenode" || return 1
}
function stopSecureHadoop(){
   local namespace="${1:-secure}"
   local resources=""
   local resource=""

   echo "Stopping Overlay: ${namespace}_hadoop (datanodes + namenode) ..."
   for app in hadoop-datanode hadoop-namenode; do
      resources="$(kubectlNames sts,deploy,pods,cm,svc -n "${namespace}" --selector="app=${app}")" || return 1
      for resource in ${resources}; do
         kubectl delete "${resource}" -n "${namespace}" --wait=false || return 1
      done
      waitForStopped "${namespace}" "${app}"
   done
}
function profileHasHue(){
   case "${1:-}" in
      standalone|mini|llap|secure|warehouse) return 0 ;;
      *) return 1 ;;
   esac
}
function hueDefaultLocalPort(){
   case "${1:-}" in
      standalone) echo 8885 ;;
      mini) echo 8886 ;;
      llap) echo 8887 ;;
      secure) echo 8888 ;;
      warehouse) echo 8889 ;;
      *) echo 8888 ;;
   esac
}
function hueDefaultNodePort(){
   case "${1:-}" in
      standalone) echo 30886 ;;
      mini) echo 30887 ;;
      llap) echo 30888 ;;
      secure) echo 30889 ;;
      warehouse) echo 30890 ;;
      *) echo "" ;;
   esac
}
# Wait until every replica of a component StatefulSet or Deployment reports Ready.
function waitForReady(){
   local namespace="$1"
   local service="$2"

   local rollout_timeout="600s"
   if [ "${service}" = "hadoop-namenode" ] || [ "${service}" = "ranger" ]; then
      rollout_timeout="1200s"
   fi
   if kubectl get statefulset "${service}" -n "${namespace}" >/dev/null 2>&1; then
      kubectl rollout status "statefulset/${service}" -n "${namespace}" --timeout="${rollout_timeout}"
   elif kubectl get deployment "${service}" -n "${namespace}" >/dev/null 2>&1; then
      kubectl rollout status "deployment/${service}" -n "${namespace}" --timeout=600s
   else
      # Components whose workloads are named differently (trino -> trino-coordinator, trino-worker)
      local workload=""
      local workloads=""
      workloads="$(kubectlNames statefulsets,deployments -n "${namespace}" --selector="app=${service}")" || return 1
      if [ -z "${workloads}" ]; then
         echo "No StatefulSet or Deployment for '${service}' in namespace '${namespace}'"
         return 1
      fi
      for workload in ${workloads}; do
         kubectl rollout status "${workload}" -n "${namespace}" --timeout="${rollout_timeout}" || return 1
      done
   fi
}
# Wait until none of the objects selected by the kubectl get arguments exist.
function waitForDeleted(){
   local timeout="$1"
   local deadline=$((SECONDS + timeout))
   local remaining=""
   shift

   while remaining="$(kubectlNames "$@")"; do
      if [ -z "${remaining}" ]; then
         return 0
      fi
      if [ "${SECONDS}" -ge "${deadline}" ]; then
         echo "Timed out after ${timeout}s waiting for the deletion of: $(echo "${remaining}" | paste -sd' ' -)"
         return 1
      fi
      sleep 2
   done
   return 1
}
# Wait until a component StatefulSet and all of its pods are deleted.
function waitForStopped(){
   local namespace="$1"
   local service="$2"

   waitForDeleted 180 statefulsets,deployments,pods -n "${namespace}" --selector="app=${service}"
}
# secure HS2: default overlay or Phase 2 Ranger authorizer (HIVECTL_SECURE_RANGER_HS2=1).
function secureHiveserver2OverlayPath(){
   if [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ]; then
      echo "./overlays/secure/hiveserver2-ranger/"
   else
      echo "./overlays/secure/hiveserver2/"
   fi
}
function applyOverlayKustomize(){
   local overlay_path="$1"
   local manifest=""
   local ranger_image=""

   manifest="$(kustomize build "${overlay_path}" --load-restrictor LoadRestrictionsNone)" || return 1
   if [[ "${overlay_path}" == *hiveserver2-ranger* ]]; then
      ranger_image="${HIVE_RANGER_IMAGE:-hive-on-k8s/hive-ranger:2.4.0-nightly}"
      manifest="$(printf '%s\n' "${manifest}" | sed "s|image: hive-on-k8s/hive-ranger:2.4.0-nightly|image: ${ranger_image}|g")"
   fi
   if [[ "${overlay_path}" == */ranger/ ]] || [[ "${overlay_path}" == */ranger ]]; then
      if [ -n "${RANGER_ADMIN_IMAGE:-}" ]; then
         manifest="$(printf '%s\n' "${manifest}" | sed "s|image: jpoblete73/ranger:2.4.0|image: ${RANGER_ADMIN_IMAGE}|g")"
      fi
      if [ -n "${HIVECTL_RANGER_EXTERNAL_URL:-}" ]; then
         manifest="$(printf '%s\n' "${manifest}" | sed "s|http://127.0.0.1:6080|${HIVECTL_RANGER_EXTERNAL_URL}|g")"
      fi
   fi
   manifest="$(portableManifestRewrite "${manifest}")"
   printf '%s\n' "${manifest}" | kubectl apply -f -
}
# Per-cluster portability (kind desktop vs EC2/Cloudera K8S). Only rewrites when the
# variable is set, so defaults (kind + local images + hive-on-k8s-local-path) are unchanged.
#   HIVE_STORAGE_CLASS_NAME  -> PVC/StatefulSet storageClassName (cluster's own class)
#   HIVE_IMAGE_REGISTRY      -> prefix for hive-on-k8s/* images (e.g. registry.example.com/hive)
function portableManifestRewrite(){
   local manifest="$1"
   local default_sc="hive-on-k8s-local-path"

   if [ -n "${HIVE_STORAGE_CLASS_NAME:-}" ] && [ "${HIVE_STORAGE_CLASS_NAME}" != "${default_sc}" ]; then
      manifest="$(printf '%s\n' "${manifest}" | sed "s|storageClassName: ${default_sc}|storageClassName: ${HIVE_STORAGE_CLASS_NAME}|g")"
   fi
   if [ -n "${HIVE_IMAGE_REGISTRY:-}" ]; then
      manifest="$(printf '%s\n' "${manifest}" | sed "s|image: hive-on-k8s/|image: ${HIVE_IMAGE_REGISTRY%/}/|g")"
   fi
   printf '%s\n' "${manifest}"
}
# Start one overlay/component and wait for its pod readiness.
function startOverlay(){
   #
   # Expects an argument: overlay_<component>
   # Ex: mini_hadoop mini_hivemetastore, mini_hiveserver2, etc
   #
   local target="$1"
   local overlay_path="./overlays/${target//_//}/"
   local namespace="${target%_*}"
   local service="${target#*_}"

   if [ "${target}" = "secure_hiveserver2" ]; then
      overlay_path="$(secureHiveserver2OverlayPath)"
      if [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ]; then
         echo "HS2 overlay: Ranger Hive plugin (Phase 2); image ${HIVE_RANGER_IMAGE:-hive-on-k8s/hive-ranger:2.4.0-nightly}"
      fi
   fi

   ensureDeployPrerequisitesOnce || return 1

   if [ "${target}" = "secure_hiveserver2" ]; then
      ensureSecureRangerHs2KindImage || return 1
   fi

   if [ "${target}" = "warehouse_llapdaemon" ]; then
      warnIfNoLlapNodes
   fi
   if [ "${target}" = "warehouse_cassandra" ]; then
      ensureWarehouseCassandraKindImage || return 1
   fi
   if [ "${namespace}" = "warehouse" ]; then
      case "${service}" in
         mysql|postgres|oracle|trino) ensureWarehouseDatabaseSecrets "${namespace}" || return 1 ;;
      esac
      case "${service}" in
         cassandra-trino|trino) ensureCassandraTrinoSecrets "${namespace}" || return 1 ;;
      esac
   fi

   if [ "${target}" = "secure_hadoop-namenode" ] || [ "${target}" = "warehouse_hadoop-namenode" ]; then
      overlayActive "${target}"
      case $? in
         0)
            echo "Overlay: ${namespace}_hadoop is already ACTIVE, try stopping/restarting it"
            # NameNode may exist without DataNodes (partial earlier start); apply the DataNode overlay if missing.
            if ! kubectl get statefulset hadoop-datanode -n "${namespace}" >/dev/null 2>&1; then
               echo "Hadoop NameNode is active but DataNodes are missing; applying DataNode overlay ..."
               kustomize build "./overlays/${namespace}/hadoop-datanode/" --load-restrictor LoadRestrictionsNone | kubectl apply -f - || return 1
            fi
            waitForReady "${namespace}" "hadoop-datanode"
            waitForReady "${namespace}" "hadoop-namenode"
            ;;
         1) startSecureHadoop "${namespace}" || return 1 ;;
         *) return 1 ;;
      esac
      return 0
   fi
   if [ "${target}" = "secure_hadoop-datanode" ] || [ "${target}" = "warehouse_hadoop-datanode" ]; then
      echo "Overlay: ${namespace}_hadoop-datanode is started with ${namespace}_hadoop-namenode (use: hiveCtl start ${namespace} hadoop-namenode)"
      return 0
   fi

   overlayActive "${target}"
   case $? in
      0)
         echo "Overlay: ${target} is already ACTIVE, try stopping/restarting it"
         ensureSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
            ensureKrb5Secrets "${namespace}" || return 1
         fi
         if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
            ensureHueSecrets "${namespace}" || return 1
         fi
         if { [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ]; } && [ "${service}" = "ranger" ]; then
            ensureRangerSecrets "${namespace}" || return 1
            if [ "${HIVECTL_RANGER_REINIT:-0}" = "1" ]; then
               reinitRangerDatabase "${namespace}" || return 1
            fi
         fi
         if [ "${namespace}" = "warehouse" ] && [ "${service}" = "impala" ]; then
            ensureImpalaKeytabs "${namespace}" || return 1
         fi
         waitForReady "${namespace}" "${service}"
         if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
            ensureKerberosKeytabSecret "${namespace}" || return 1
         fi
         ;;
      1)
         if overlayExists "${target}"; then
            echo "Starting Overlay: ${target} ..."
            ensureSecrets "${namespace}" || return 1
            ensureAdminSecrets "${namespace}" || return 1
            if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
               ensureKrb5Secrets "${namespace}" || return 1
            fi
            if [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ]; then
               case "${service}" in
                  krb5kdc)
                     ;;
                  hadoop-namenode|hadoop-datanode|hivemetastore|hiveserver2|llapdaemon|zookeeper|cassandra|hue|trino)
                     ensureKerberosKeytabSecret "${namespace}" || return 1
                     ;;
                  impala)
                     ensureKerberosKeytabSecret "${namespace}" || return 1
                     ensureImpalaKeytabs "${namespace}" || return 1
                     ;;
               esac
            fi
            if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
               ensureHueSecrets "${namespace}" || return 1
            fi
            if { [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ]; } && [ "${service}" = "ranger" ]; then
               ensureRangerSecrets "${namespace}" || return 1
               if [ "${HIVECTL_RANGER_REINIT:-0}" = "1" ]; then
                  reinitRangerDatabase "${namespace}" || return 1
               fi
            fi
            applyOverlayKustomize "${overlay_path}" || return 1
            if { [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ]; } && [ "${service}" = "ranger" ]; then
               waitForRangerMysqlInit "${namespace}" || return 1
            fi
            waitForReady "${namespace}" "${service}"
            if [ "${namespace}" = "secure" ] && [ "${service}" = "krb5kdc" ]; then
               ensureKerberosKeytabSecret "${namespace}" || return 1
            fi
         else
            echo "Overlay: ${target} DOES NOT EXIST"
         fi
         ;;
      *)
         return 1
         ;;
   esac

   if [ "${namespace}" = "warehouse" ]; then
      case "${service}" in
         cassandra-trino) ensureCassandraTrinoRole "${namespace}" || return 1 ;;
         mysql|postgres|oracle) applyWarehouseDatabaseSchema "${namespace}" "${service}" || return 1 ;;
      esac
   fi
   if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
      ensureHuePortForward "${namespace}" || true
   fi
   if [ "${namespace}" = "secure" ] && [ "${service}" = "ranger" ]; then
      ensureRangerPortForward "${namespace}" || true
   fi
   if [ "${namespace}" = "secure" ] && [ "${service}" = "hiveserver2" ]; then
      # Policies must exist before schematool. The plugin denies CREATE until it polls them.
      if ! ensureSecureRangerHiveBootstrap "${namespace}"; then
         echo "Ranger Hive bootstrap failed; Hive SYS schema init needs secure_hive policies" >&2
         return 1
      fi
      if [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ] && ! secureRangerHiveBootstrapDisabled; then
         echo "Waiting 35s for HS2 to poll Ranger policies before Hive SYS schema init ..."
         sleep 35
      fi
   fi
   if hs2OverlayServiceStarted "${namespace}" "${service}"; then
      ensureHs2PortForward "${namespace}" || true
      ensureHiveSysSchema "${namespace}" || return 1
   fi
   if [ "${service}" = "llapdaemon" ]; then
      case "${namespace}" in llap|secure) ensureLlapDaemonPortForward "${namespace}" || true ;; esac
   fi
}
# Stop one overlay/component while preserving PVCs.
function stopOverlay(){
   #
   # Expects an argument: overlay_<component>
   # Ex: mini_hivemetastore, mini_hiveserver2, etc
   #
   local target="$1"
   local namespace="${target%_*}"
   local service="${target#*_}"
   local resources=""
   local resource=""

   if [ "${target}" = "secure_hadoop-datanode" ] || [ "${target}" = "warehouse_hadoop-datanode" ]; then
      echo "Overlay: ${namespace}_hadoop-datanode stops with ${namespace}_hadoop-namenode (use: hiveCtl stop ${namespace} hadoop-namenode)"
      return 0
   fi
   if [ "${target}" = "secure_hadoop-namenode" ] || [ "${target}" = "warehouse_hadoop-namenode" ]; then
      stopSecureHadoop "${namespace}"
      return $?
   fi

   overlayActive "${target}"
   case $? in
      0) ;;
      1)
         echo "Overlay: ${target} is already STOPPED or DOES NOT EXIST"
         return 0
         ;;
      *)
         return 1
         ;;
   esac

   echo "Stopping Overlay: ${target} ..."
   if profileHasHue "${namespace}" && [ "${service}" = "hue" ]; then
      stopHuePortForward "${namespace}"
   fi
   if hs2OverlayServiceStarted "${namespace}" "${service}"; then
      stopHs2PortForward "${namespace}"
   fi
   if [ "${service}" = "llapdaemon" ]; then
      case "${namespace}" in llap|secure) stopLlapDaemonPortForward "${namespace}" ;; esac
   fi
   if [ "${service}" = "ranger" ]; then
      stopRangerPortForward "${namespace}"
      kubectl delete job ranger-mysql-init -n "${namespace}" --ignore-not-found --wait=false || return 1
   fi
   resources="$(kubectlNames sts,deploy,pods,cm,svc -n "${namespace}" --selector="app=${service}")" || return 1
   # Not forced: each pod gets its termination grace period to shut its services down cleanly
   for resource in ${resources}; do
      kubectl delete "${resource}" -n "${namespace}" --wait=false || return 1
   done
   waitForStopped "${namespace}" "${service}"
}
# State under repo .hivectl/ (port-forward pid for Hue).
function hiveCtlStateDir(){
   local root=""
   root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   echo "${HIVECTL_STATE_DIR:-${root}/.hivectl}"
}
function huePortForwardPidFile(){
   local namespace="${1:-llap}"
   echo "$(hiveCtlStateDir)/${namespace}-hue-portforward.pid"
}
function huePortForwardMonitorPidFile(){
   local namespace="${1:-llap}"
   echo "$(hiveCtlStateDir)/${namespace}-hue-portforward-monitor.pid"
}
function hueLocalPort(){
   local namespace="${1:-}"

   if [ -n "${HIVECTL_HUE_LOCAL_PORT:-}" ]; then
      echo "${HIVECTL_HUE_LOCAL_PORT}"
      return 0
   fi
   if [ -n "${namespace}" ]; then
      hueDefaultLocalPort "${namespace}"
      return 0
   fi
   echo 8888
}
function hueLocalPortConflictMessage(){
   local namespace="$1"
   local port="$2"
   local other=""
   local pidfile=""
   local other_port=""

   for other in standalone mini llap secure warehouse; do
      [ "${other}" = "${namespace}" ] && continue
      pidfile="$(huePortForwardPidFile "${other}")"
      [ -f "${pidfile}" ] || continue
      other_port="$(hueLocalPort "${other}")"
      if [ "${other_port}" = "${port}" ]; then
         echo "Hue port-forward for '${other}' already uses localhost:${port}; set HIVECTL_HUE_LOCAL_PORT for '${namespace}'."
         return 0
      fi
   done
   return 1
}
function huePortForwardDisabled(){
   case "${HIVECTL_HUE_PORT_FORWARD:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function huePortForwardMonitorDisabled(){
   case "${HIVECTL_HUE_PORT_FORWARD_MONITOR:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
# True when hue-0 exists and its Ready condition is True.
function huePodRunningAndReady(){
   local namespace="${1:-${HIVECTL_HUE_NAMESPACE:-llap}}"
   local phase=""
   local ready=""

   phase="$(kubectl get pod hue-0 -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null)" || return 1
   [ "${phase}" = "Running" ] || return 1
   ready="$(kubectl get pod hue-0 -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || return 1
   [ "${ready}" = "True" ] || return 1
}
# True when Hue responds on localhost (kind mapping or port-forward).
function hueLocalUrlReachable(){
   local port="$1"
   local code=""
   local attempt=0

   [ -n "${port}" ] || return 1
   command -v curl >/dev/null 2>&1 || return 1
   while [ "${attempt}" -lt 3 ]; do
      code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/hue/accounts/login" --connect-timeout 3 --max-time 8 2>/dev/null || echo 000)"
      case "${code}" in
         200|301|302|303|401|403|404) return 0 ;;
      esac
      attempt=$((attempt + 1))
      sleep 1
   done
   return 1
}
function huePortForwardProcessAlive(){
   local namespace="$1"
   local pidfile=""
   local pid=""

   pidfile="$(huePortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 1
   pid="$(cat "${pidfile}")"
   [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}
function stopHuePortForwardMonitor(){
   local namespace="${1:-llap}"
   local pidfile=""
   local pid=""

   pidfile="$(huePortForwardMonitorPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
# Start kubectl port-forward to svc/hue (replaces a stale forward when localhost is down).
function startHuePortForwardProcess(){
   local namespace="${1:-${HIVECTL_HUE_NAMESPACE:-llap}}"
   local port=""
   local pidfile=""
   local pid=""

   port="$(hueLocalPort "${namespace}")"
   pidfile="$(huePortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if hueLocalPortConflictMessage "${namespace}" "${port}" >/dev/null; then
      hueLocalPortConflictMessage "${namespace}" "${port}" >&2
      return 1
   fi

   if huePortForwardProcessAlive "${namespace}"; then
      if hueLocalUrlReachable "${port}"; then
         return 0
      fi
      pid="$(cat "${pidfile}")"
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      rm -f "${pidfile}"
   fi

   nohup kubectl port-forward "svc/hue" -n "${namespace}" "${port}:8888" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if kill -0 "${pid}" 2>/dev/null; then
      return 0
   fi
   rm -f "${pidfile}"
   return 1
}
# Internal loop: invoked via hiveCtl __hue-portforward-monitor (nohup background).
function huePortForwardMonitorLoop(){
   local namespace="${HIVECTL_HUE_NAMESPACE:-llap}"
   local interval=""
   local port=""

   interval="${HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL:-60}"
   while true; do
      sleep "${interval}"
      if huePortForwardDisabled; then
         exit 0
      fi
      if huePortForwardMonitorDisabled; then
         exit 0
      fi
      if ! kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
         continue
      fi
      if ! huePodRunningAndReady "${namespace}"; then
         continue
      fi
      port="$(hueLocalPort "${namespace}")"
      if huePortForwardProcessAlive "${namespace}" && hueLocalUrlReachable "${port}"; then
         continue
      fi
      if huePortForwardProcessAlive "${namespace}" && ! hueLocalUrlReachable "${port}"; then
         sleep 5
         if hueLocalUrlReachable "${port}"; then
            continue
         fi
      fi
      echo "[hiveCtl] Hue http://127.0.0.1:${port}/ unreachable while hue-0 is Ready; restarting port-forward" >&2
      if startHuePortForwardProcess "${namespace}"; then
         echo "[hiveCtl] Hue port-forward restarted (pid $(cat "$(huePortForwardPidFile "${namespace}")" 2>/dev/null))" >&2
      else
         echo "[hiveCtl] Warning: could not restart Hue port-forward to localhost:${port}" >&2
      fi
   done
}
function startHuePortForwardMonitor(){
   local namespace="${1:-llap}"
   local monitor_pidfile=""
   local logfile=""
   local hivectl=""
   local pid=""

   if huePortForwardDisabled || huePortForwardMonitorDisabled; then
      return 0
   fi
   if ! kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   monitor_pidfile="$(huePortForwardMonitorPidFile "${namespace}")"
   if [ -f "${monitor_pidfile}" ]; then
      pid="$(cat "${monitor_pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         return 0
      fi
      rm -f "${monitor_pidfile}"
   fi

   mkdir -p "$(hiveCtlStateDir)"
   logfile="$(hiveCtlStateDir)/${namespace}-hue-portforward-monitor.log"
   hivectl="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
   nohup env HIVECTL_STATE_DIR="$(hiveCtlStateDir)" \
      HIVECTL_HUE_NAMESPACE="${namespace}" \
      HIVECTL_HUE_LOCAL_PORT="$(hueLocalPort "${namespace}")" \
      HIVECTL_HUE_PORT_FORWARD="${HIVECTL_HUE_PORT_FORWARD:-auto}" \
      HIVECTL_HUE_PORT_FORWARD_MONITOR="${HIVECTL_HUE_PORT_FORWARD_MONITOR:-1}" \
      HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL="${HIVECTL_HUE_PORT_FORWARD_MONITOR_INTERVAL:-60}" \
      bash "${hivectl}" __hue-portforward-monitor >>"${logfile}" 2>&1 &
   pid=$!
   echo "${pid}" > "${monitor_pidfile}"
}
# Stop background kubectl port-forward and its monitor.
function stopHuePortForward(){
   local namespace="${1:-llap}"
   local pidfile=""
   local pid=""

   stopHuePortForwardMonitor "${namespace}"
   pidfile="$(huePortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
function printHueLoginHint(){
   echo "Hue login (${1}): user admin, password: ./hiveCtl.sh get passwd ${1} hue-admin"
}
# Expose Hue on localhost after hue is up (skipped when HIVECTL_HUE_PORT_FORWARD=0).
function ensureHuePortForward(){
   local namespace="${1:-llap}"
   local port=""
   local pidfile=""
   local pid=""

   if huePortForwardDisabled; then
      stopHuePortForward "${namespace}"
      echo "Hue port-forward disabled (HIVECTL_HUE_PORT_FORWARD=${HIVECTL_HUE_PORT_FORWARD})"
      kubectl get svc hue -n "${namespace}" >/dev/null 2>&1 && printHueLoginHint "${namespace}"
      return 0
   fi

   if ! kubectl get svc hue -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi
   printHueLoginHint "${namespace}"

   port="$(hueLocalPort "${namespace}")"
   pidfile="$(huePortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if hueLocalPortConflictMessage "${namespace}" "${port}" >/dev/null; then
      hueLocalPortConflictMessage "${namespace}" "${port}" >&2
      return 1
   fi

   if huePortForwardProcessAlive "${namespace}" && hueLocalUrlReachable "${port}"; then
      pid="$(cat "${pidfile}")"
      np="$(hueDefaultNodePort "${namespace}")"
      if [ -n "${np}" ]; then
         echo "Hue UI (${namespace}): http://127.0.0.1:${port}/hue/accounts/login (port-forward pid ${pid}; NodePort ${np})"
      else
         echo "Hue UI (${namespace}): http://127.0.0.1:${port}/hue/accounts/login (port-forward pid ${pid})"
      fi
      startHuePortForwardMonitor "${namespace}" || true
      return 0
   fi

   if startHuePortForwardProcess "${namespace}"; then
      pid="$(cat "${pidfile}")"
      np="$(hueDefaultNodePort "${namespace}")"
      if [ -n "${np}" ]; then
         echo "Hue UI (${namespace}): http://127.0.0.1:${port}/hue/accounts/login (hiveCtl port-forward pid ${pid}; NodePort ${np}; stops on './hiveCtl.sh stop ${namespace} hue')"
      else
         echo "Hue UI (${namespace}): http://127.0.0.1:${port}/hue/accounts/login (hiveCtl port-forward pid ${pid}; stops on './hiveCtl.sh stop ${namespace} hue')"
      fi
      startHuePortForwardMonitor "${namespace}" || true
      return 0
   fi
   echo "Warning: could not bind localhost:${port} for Hue. Try: kubectl port-forward svc/hue -n ${namespace} ${port}:8888" >&2
   startHuePortForwardMonitor "${namespace}" || true
   return 1
}
function profileHasHs2Service(){
   case "${1:-}" in
      standalone|mini|llap|secure) return 0 ;;
      *) return 1 ;;
   esac
}
function hs2LocalPortBase(){
   local namespace="${1:-}"

   if [ -n "${HIVECTL_HS2_LOCAL_PORT_BASE:-}" ]; then
      echo "${HIVECTL_HS2_LOCAL_PORT_BASE}"
      return 0
   fi
   case "${namespace}" in
      standalone) echo 11000 ;;
      mini) echo 11100 ;;
      llap) echo 11200 ;;
      secure) echo 11300 ;;
      warehouse) echo 11400 ;;
      *) echo 11000 ;;
   esac
}
function hs2LocalPort(){
   local namespace="$1"
   local which="$2"
   local base=""

   base="$(hs2LocalPortBase "${namespace}")"
   case "${which}" in
      binary|0) echo $((base + 0)) ;;
      http|1) echo $((base + 1)) ;;
      webui|2) echo $((base + 2)) ;;
      *) echo "${base}" ;;
   esac
}
function hs2DefaultNodePort(){
   local namespace="$1"
   local which="$2"
   local base=""

   case "${namespace}" in
      standalone) base=31000 ;;
      mini) base=31010 ;;
      llap) base=31020 ;;
      secure) base=31030 ;;
      *) base=31000 ;;
   esac
   case "${which}" in
      binary|0) echo $((base + 0)) ;;
      http|1) echo $((base + 1)) ;;
      webui|2) echo $((base + 2)) ;;
      *) echo "${base}" ;;
   esac
}
function hs2PortForwardPidFile(){
   local namespace="${1:-mini}"
   echo "$(hiveCtlStateDir)/${namespace}-hs2-portforward.pid"
}
function hs2WebUiProxyPidFile(){
   local namespace="${1:-mini}"
   echo "$(hiveCtlStateDir)/${namespace}-hs2-webui-proxy.pid"
}
function hs2WebUiUpstreamPidFile(){
   local namespace="${1:-mini}"
   echo "$(hiveCtlStateDir)/${namespace}-hs2-webui-upstream-pf.pid"
}
# Loopback-only kubectl target for HS2 Web UI (Host header must stay :10002 for Hive HttpServer).
function hs2WebUiUpstreamPort(){
   case "${1:-}" in
      standalone) echo 40000 ;;
      mini) echo 40100 ;;
      llap) echo 40200 ;;
      secure) echo 40300 ;;
      *) echo 40100 ;;
   esac
}
function hs2WebUiProxyScript(){
   echo "${HIVECTL_ROOT}/scripts/hs2-webui-proxy.py"
}
function hs2PortForwardDisabled(){
   case "${HIVECTL_HS2_PORT_FORWARD:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function hs2PortForwardProcessAlive(){
   local namespace="$1"
   local pidfile=""
   local pid=""

   pidfile="$(hs2PortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 1
   pid="$(cat "${pidfile}")"
   [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}
function hs2LocalPortConflictMessage(){
   local namespace="$1"
   local other=""
   local pidfile=""
   local p=""
   local op=""
   local ports=""
   local oports=""

   ports="$(hs2LocalPort "${namespace}" binary) $(hs2LocalPort "${namespace}" http) $(hs2LocalPort "${namespace}" webui)"
   for other in standalone mini llap secure warehouse; do
      [ "${other}" = "${namespace}" ] && continue
      pidfile="$(hs2PortForwardPidFile "${other}")"
      [ -f "${pidfile}" ] || continue
      oports="$(hs2LocalPort "${other}" binary) $(hs2LocalPort "${other}" http) $(hs2LocalPort "${other}" webui)"
      for p in ${ports}; do
         for op in ${oports}; do
            if [ "${p}" = "${op}" ]; then
               echo "HS2 port-forward for '${other}' already uses localhost:${p}; set HIVECTL_HS2_LOCAL_PORT_BASE for '${namespace}'."
               return 0
            fi
         done
      done
   done
   return 1
}
function stopHs2PortForward(){
   local namespace="${1:-mini}"
   local pidfile=""
   local pid=""

   pidfile="$(hs2WebUiProxyPidFile "${namespace}")"
   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         kill "${pid}" 2>/dev/null || true
         wait "${pid}" 2>/dev/null || true
      fi
      rm -f "${pidfile}"
   fi
   pidfile="$(hs2WebUiUpstreamPidFile "${namespace}")"
   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         kill "${pid}" 2>/dev/null || true
         wait "${pid}" 2>/dev/null || true
      fi
      rm -f "${pidfile}"
   fi
   pidfile="$(hs2PortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
function startHs2PortForwardProcess(){
   local namespace="$1"
   local pidfile=""
   local proxy_pidfile=""
   local pid=""
   local proxy_pid=""
   local lb=""
   local lh=""
   local lw=""
   local upstream=""
   local proxy_script=""

   lb="$(hs2LocalPort "${namespace}" binary)"
   lh="$(hs2LocalPort "${namespace}" http)"
   lw="$(hs2LocalPort "${namespace}" webui)"
   upstream="$(hs2WebUiUpstreamPort "${namespace}")"
   pidfile="$(hs2PortForwardPidFile "${namespace}")"
   proxy_pidfile="$(hs2WebUiProxyPidFile "${namespace}")"
   proxy_script="$(hs2WebUiProxyScript)"

   if hs2LocalPortConflictMessage "${namespace}" >/dev/null; then
      hs2LocalPortConflictMessage "${namespace}" >&2
      return 1
   fi

   if hs2PortForwardProcessAlive "${namespace}"; then
      stopHs2PortForward "${namespace}"
   fi

   if [ ! -f "${proxy_script}" ]; then
      echo "Missing ${proxy_script} (HS2 Web UI proxy)" >&2
      return 1
   fi

   nohup kubectl port-forward --address 127.0.0.1 "svc/hiveserver2" -n "${namespace}" \
      "${lb}:10000" "${lh}:10001" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if ! kill -0 "${pid}" 2>/dev/null; then
      rm -f "${pidfile}"
      return 1
   fi
   nohup kubectl port-forward --address 127.0.0.1 "svc/hiveserver2" -n "${namespace}" \
      "${upstream}:10002" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "$(hs2WebUiUpstreamPidFile "${namespace}")"
   sleep 1
   if ! kill -0 "${pid}" 2>/dev/null; then
      stopHs2PortForward "${namespace}"
      return 1
   fi

   nohup python3 "${proxy_script}" --listen-port "${lw}" --upstream-port "${upstream}" >/dev/null 2>&1 &
   proxy_pid=$!
   echo "${proxy_pid}" > "${proxy_pidfile}"
   sleep 1
   kill -0 "${proxy_pid}" 2>/dev/null
}
function ensureHs2PortForward(){
   local namespace="${1:-mini}"
   local pidfile=""
   local pid=""
   local lb=""
   local lh=""
   local lw=""
   local nb=""
   local nh=""
   local nw=""

   if hs2PortForwardDisabled; then
      stopHs2PortForward "${namespace}"
      echo "HiveServer2 port-forward disabled (HIVECTL_HS2_PORT_FORWARD=${HIVECTL_HS2_PORT_FORWARD})"
      return 0
   fi

   profileHasHs2Service "${namespace}" || return 0
   if ! kubectl get svc hiveserver2 -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   lb="$(hs2LocalPort "${namespace}" binary)"
   lh="$(hs2LocalPort "${namespace}" http)"
   lw="$(hs2LocalPort "${namespace}" webui)"
   pidfile="$(hs2PortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if hs2LocalPortConflictMessage "${namespace}" >/dev/null; then
      hs2LocalPortConflictMessage "${namespace}" >&2
      return 1
   fi

   nb="$(hs2DefaultNodePort "${namespace}" binary)"
   nh="$(hs2DefaultNodePort "${namespace}" http)"
   nw="$(hs2DefaultNodePort "${namespace}" webui)"

   if hs2PortForwardProcessAlive "${namespace}"; then
      pid="$(cat "${pidfile}")"
      echo "HiveServer2 (${namespace}): jdbc/beeline localhost:${lb} · http ${lh} · webui http://127.0.0.1:${lw}/ (pf pid ${pid}; NodePorts ${nb}/${nh}/${nw})"
      return 0
   fi

   if startHs2PortForwardProcess "${namespace}"; then
      local proxy_pid=""
      pid="$(cat "${pidfile}")"
      proxy_pid="$(cat "$(hs2WebUiProxyPidFile "${namespace}")" 2>/dev/null)"
      echo "HiveServer2 (${namespace}): jdbc/beeline localhost:${lb} · http ${lh} · webui http://127.0.0.1:${lw}/ (proxy pid ${proxy_pid:-?}; pf pid ${pid}; NodePorts ${nb}/${nh}/${nw})"
      return 0
   fi
   echo "Warning: could not bind HS2 localhost ports ${lb}/${lh}/${lw}. Try: kubectl port-forward svc/hiveserver2 -n ${namespace} ${lb}:10000 ${lh}:10001 ${lw}:10002" >&2
   return 1
}
function ensureHs2PortForwardsForActiveProfiles(){
   local ns=""

   for ns in standalone mini llap secure warehouse; do
      profileHasHs2Service "${ns}" || continue
      kubectl get namespace "${ns}" >/dev/null 2>&1 || continue
      kubectl get svc hiveserver2 -n "${ns}" >/dev/null 2>&1 || continue
      ensureHs2PortForward "${ns}" || true
   done
}
function hs2OverlayServiceStarted(){
   local namespace="$1"
   local service="$2"

   case "${namespace}" in
      standalone)
         [ "${service}" = "hive" ] && return 0
         ;;
      mini|llap|secure|warehouse)
         [ "${service}" = "hiveserver2" ] && return 0
         ;;
   esac
   return 1
}
# True when automatic schematool -initSchema -dbType hive should be skipped.
function hiveSysSchemaDisabled(){
   case "${HIVECTL_HIVE_SYS_SCHEMA:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
# Return 0 when schematool output means the Hive SYS schema is already present.
function hiveSysSchemaAlreadyInitialized(){
   local log="$1"

   printf '%s\n' "${log}" | grep -Eiq \
      "already initialized|database '?sys'? already exists|duplicate entry 'sys'|table 'sys\\.version' already exists"
}
# Return 0 when the Hive sys database is already recorded.
# MySQL: hive.DBS. Derby: warehouse directory, because embedded Derby stays locked by the Metastore JVM.
# Return 1 when the schema is absent or the check cannot be run (caller may still try schematool).
function hiveSysSchemaPresent(){
   local namespace="$1"
   local meta_db="$2"
   local count=""

   case "${meta_db}" in
      mysql)
         kubectl get pod mysql-0 -n "${namespace}" >/dev/null 2>&1 || return 1
         count="$(kubectl exec mysql-0 -n "${namespace}" -- \
            sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM hive.DBS WHERE LOWER(NAME)='"'"'sys'"'"'"' 2>/dev/null)" || return 1
         count="${count//[[:space:]]/}"
         [ -n "${count}" ] && [ "${count}" -ge 1 ]
         ;;
      derby)
         kubectl get pod hive-0 -n "${namespace}" >/dev/null 2>&1 || return 1
         kubectl exec hive-0 -n "${namespace}" -c hiveserver2 -- \
            bash -c 'test -d /opt/hive/data/warehouse/sys.db || test -d /opt/hive/data/warehouse/SYS.db'
         ;;
      *)
         return 1
         ;;
   esac
}
# Run schematool -initSchema -dbType hive on one Ready HS2 pod. Retries while ZK/Kerberos JDBC comes up.
function hiveSysSchemaInitOnPod(){
   local namespace="$1"
   local pod="$2"
   local meta_db="$3"
   local kerberos="$4"
   shift 4
   local attempt=1
   local max_attempts="${HIVECTL_HIVE_SYS_SCHEMA_ATTEMPTS:-6}"
   local delay="${HIVECTL_HIVE_SYS_SCHEMA_RETRY_SEC:-10}"
   local log=""
   local status=0
   local remote=""

   remote="$(cat <<'EOS'
set -eu
url="${BEELINE_URL:-}"
if [ -z "${url}" ]; then
  echo "BEELINE_URL is empty on this HiveServer2 pod" >&2
  exit 1
fi
cat > /tmp/hive-sys-schema-init.sh << 'EOF'
#!/bin/bash
set -eu
if [ "${HIVE_SYS_KERBEROS:-0}" = "1" ]; then
  fqdn="$(hostname -f)"
  realm="${KRB5_REALM:-SECURE.LAB}"
  [ -f /home/hive/host-service.keytab ] || { echo "missing /home/hive/host-service.keytab" >&2; exit 1; }
  kinit -kt /home/hive/host-service.keytab "hive/${fqdn}@${realm}"
fi
url="${BEELINE_URL:?BEELINE_URL is empty}"
# HS2 startup renames hive-beeline-*-standalone.jar so Jetty will not unpack it.
# The fat jar Main-Class is BeeLine, so hadoop jar must not use it as the job jar.
# HiveSchemaTool is only inside it: put it on HADOOP_CLASSPATH and let schematool
# launch via hive-cli (no Main-Class), which honors the HiveSchemaTool class name.
export USE_DEPRECATED_CLI=true
shopt -s nullglob
off_jars=("${HIVE_HOME:-/opt/hive}/lib"/hive-beeline-*-standalone.jar.off-hs2-webui)
if [ "${#off_jars[@]}" -eq 0 ]; then
  # docker/hive-ranger moves the fat jar to beeline-client at image build.
  off_jars=("${HIVE_HOME:-/opt/hive}/beeline-client"/hive-beeline-*-standalone.jar)
fi
if [ "${#off_jars[@]}" -gt 0 ]; then
  export HADOOP_CLASSPATH="${off_jars[0]}${HADOOP_CLASSPATH:+:${HADOOP_CLASSPATH}}"
fi
schematool="${HIVE_HOME:-/opt/hive}/bin/schematool"
quoted_url="$(printf '%q' "${url}")"
if command -v script >/dev/null 2>&1; then
  # kubectl exec has no pty; HiveSchemaTool still initializes JLine.
  script -q -e -c "${schematool} -initSchema -dbType hive -metaDbType ${HIVE_SYS_META_DB:?} -url ${quoted_url}" /dev/null
else
  "${schematool}" -initSchema -dbType hive -metaDbType "${HIVE_SYS_META_DB:?}" -url "${url}"
fi
EOF
chmod 755 /tmp/hive-sys-schema-init.sh
chown hive:hive /tmp/hive-sys-schema-init.sh
su -s /bin/bash hive -c "BEELINE_URL=$(printf '%q' "${url}") HIVE_HOME=$(printf '%q' "${HIVE_HOME:-/opt/hive}") HIVE_SYS_META_DB=$(printf '%q' "${HIVE_SYS_META_DB}") HIVE_SYS_KERBEROS=$(printf '%q' "${HIVE_SYS_KERBEROS:-0}") KRB5_REALM=$(printf '%q' "${KRB5_REALM:-SECURE.LAB}") /tmp/hive-sys-schema-init.sh"
EOS
)"

   while [ "${attempt}" -le "${max_attempts}" ]; do
      log="$(kubectl exec -n "${namespace}" "${pod}" "$@" -- \
         env HIVE_SYS_META_DB="${meta_db}" HIVE_SYS_KERBEROS="${kerberos}" \
         bash -c "${remote}" 2>&1)" && status=0 || status=$?
      printf '%s\n' "${log}"
      if [ "${status}" -eq 0 ]; then
         return 0
      fi
      if hiveSysSchemaAlreadyInitialized "${log}"; then
         return 0
      fi
      if hiveSysSchemaPresent "${namespace}" "${meta_db}"; then
         echo "Hive SYS schema is present in the metastore (${namespace}); treating init as done"
         return 0
      fi
      if [ "${attempt}" -ge "${max_attempts}" ]; then
         echo "Hive SYS schema init failed after ${max_attempts} attempts on ${namespace}/${pod}" >&2
         return 1
      fi
      echo "Hive SYS schema init attempt ${attempt}/${max_attempts} failed on ${namespace}/${pod}; retrying in ${delay}s (HiveServer2 JDBC may still be registering)"
      attempt=$((attempt + 1))
      sleep "${delay}"
   done
   return 1
}
# Initialize the Hive SYS schema once HiveServer2 is Ready. Idempotent when sys already exists.
function ensureHiveSysSchema(){
   local namespace="$1"
   local meta_db="mysql"
   local pod=""
   local kerberos=0
   local container_args=()

   if hiveSysSchemaDisabled; then
      echo "Hive SYS schema init disabled (HIVECTL_HIVE_SYS_SCHEMA=${HIVECTL_HIVE_SYS_SCHEMA})"
      return 0
   fi

   case "${namespace}" in
      standalone)
         meta_db="derby"
         pod="hive-0"
         container_args=(-c hiveserver2)
         ;;
      mini|llap|secure|warehouse)
         meta_db="mysql"
         pod="hiveserver2-0"
         { [ "${namespace}" = "secure" ] || [ "${namespace}" = "warehouse" ]; } && kerberos=1
         ;;
      *)
         echo "Hive SYS schema init: no handler for namespace '${namespace}'; skipping"
         return 0
         ;;
   esac

   if hiveSysSchemaPresent "${namespace}" "${meta_db}"; then
      echo "Hive SYS schema already initialized (${namespace}); skipping schematool -initSchema"
      return 0
   fi

   echo "Initializing Hive SYS schema on ${namespace}/${pod} (metaDbType=${meta_db}, JDBC URL from pod BEELINE_URL) ..."
   hiveSysSchemaInitOnPod "${namespace}" "${pod}" "${meta_db}" "${kerberos}" "${container_args[@]}"
}
function rangerPortForwardPidFile(){
   local namespace="${1:-secure}"
   echo "$(hiveCtlStateDir)/${namespace}-ranger-portforward.pid"
}
function rangerPortForwardMonitorPidFile(){
   local namespace="${1:-secure}"
   echo "$(hiveCtlStateDir)/${namespace}-ranger-portforward-monitor.pid"
}
function rangerLocalPort(){
   echo "${HIVECTL_RANGER_LOCAL_PORT:-6080}"
}
function rangerPortForwardDisabled(){
   case "${HIVECTL_RANGER_PORT_FORWARD:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function rangerPortForwardMonitorDisabled(){
   case "${HIVECTL_RANGER_PORT_FORWARD_MONITOR:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
      *) return 1 ;;
   esac
}
function rangerPodRunningAndReady(){
   local namespace="${1:-secure}"
   local phase=""
   local ready=""

   phase="$(kubectl get pod ranger-0 -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null)" || return 1
   [ "${phase}" = "Running" ] || return 1
   ready="$(kubectl get pod ranger-0 -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || return 1
   [ "${ready}" = "True" ] || return 1
}
function rangerLocalUrlReachable(){
   local port="$1"
   local code=""

   [ -n "${port}" ] || return 1
   command -v curl >/dev/null 2>&1 || return 1
   code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/login.jsp" --connect-timeout 2 2>/dev/null || echo 000)"
   case "${code}" in
      200|301|302|303|401|403|404) return 0 ;;
      *) return 1 ;;
   esac
}
function stopRangerPortForwardMonitor(){
   local namespace="${1:-secure}"
   local pidfile=""
   local pid=""

   pidfile="$(rangerPortForwardMonitorPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
function startRangerPortForwardProcess(){
   local namespace="${1:-secure}"
   local port=""
   local pidfile=""
   local pid=""

   port="$(rangerLocalPort)"
   pidfile="$(rangerPortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         if rangerLocalUrlReachable "${port}"; then
            return 0
         fi
         kill "${pid}" 2>/dev/null || true
         wait "${pid}" 2>/dev/null || true
      fi
      rm -f "${pidfile}"
   fi

   nohup kubectl port-forward "svc/ranger" -n "${namespace}" "${port}:6080" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if kill -0 "${pid}" 2>/dev/null; then
      return 0
   fi
   rm -f "${pidfile}"
   return 1
}
function rangerPortForwardMonitorLoop(){
   local namespace="${HIVECTL_RANGER_NAMESPACE:-secure}"
   local interval=""
   local port=""

   interval="${HIVECTL_RANGER_PORT_FORWARD_MONITOR_INTERVAL:-60}"
   while true; do
      sleep "${interval}"
      if rangerPortForwardDisabled; then
         exit 0
      fi
      if rangerPortForwardMonitorDisabled; then
         exit 0
      fi
      if ! kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
         continue
      fi
      if ! rangerPodRunningAndReady "${namespace}"; then
         continue
      fi
      port="$(rangerLocalPort)"
      if rangerLocalUrlReachable "${port}"; then
         continue
      fi
      echo "[hiveCtl] Ranger http://127.0.0.1:${port}/login.jsp unreachable while ranger-0 is Ready; restarting port-forward" >&2
      if startRangerPortForwardProcess "${namespace}"; then
         echo "[hiveCtl] Ranger port-forward restarted (pid $(cat "$(rangerPortForwardPidFile "${namespace}")" 2>/dev/null))" >&2
      else
         echo "[hiveCtl] Warning: could not restart Ranger port-forward to localhost:${port}" >&2
      fi
   done
}
function startRangerPortForwardMonitor(){
   local namespace="${1:-secure}"
   local monitor_pidfile=""
   local logfile=""
   local hivectl=""
   local pid=""

   if rangerPortForwardDisabled || rangerPortForwardMonitorDisabled; then
      return 0
   fi
   if ! kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   monitor_pidfile="$(rangerPortForwardMonitorPidFile "${namespace}")"
   if [ -f "${monitor_pidfile}" ]; then
      pid="$(cat "${monitor_pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         return 0
      fi
      rm -f "${monitor_pidfile}"
   fi

   mkdir -p "$(hiveCtlStateDir)"
   logfile="$(hiveCtlStateDir)/${namespace}-ranger-portforward-monitor.log"
   hivectl="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
   nohup env HIVECTL_STATE_DIR="$(hiveCtlStateDir)" \
      HIVECTL_RANGER_NAMESPACE="${namespace}" \
      HIVECTL_RANGER_LOCAL_PORT="$(rangerLocalPort)" \
      HIVECTL_RANGER_PORT_FORWARD="${HIVECTL_RANGER_PORT_FORWARD:-auto}" \
      HIVECTL_RANGER_PORT_FORWARD_MONITOR="${HIVECTL_RANGER_PORT_FORWARD_MONITOR:-1}" \
      HIVECTL_RANGER_PORT_FORWARD_MONITOR_INTERVAL="${HIVECTL_RANGER_PORT_FORWARD_MONITOR_INTERVAL:-60}" \
      bash "${hivectl}" __ranger-portforward-monitor >>"${logfile}" 2>&1 &
   pid=$!
   echo "${pid}" > "${monitor_pidfile}"
}
function stopRangerPortForward(){
   local namespace="${1:-secure}"
   local pidfile=""
   local pid=""

   stopRangerPortForwardMonitor "${namespace}"
   pidfile="$(rangerPortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
function rangerAdminPasswordHint(){
   local namespace="${1:-secure}"
   echo "Ranger login user: admin   password: kubectl get secret hive-credentials -n ${namespace} -o jsonpath='{.data.ranger-admin-password}' | base64 -d; echo"
}
# True when automatic secure_hive + admin policy bootstrap should be skipped.
function secureRangerHiveBootstrapDisabled(){
   case "${HIVECTL_SECURE_RANGER_BOOTSTRAP_HIVE:-auto}" in
      0|false|no|off|disable|disabled) return 0 ;;
      auto)
         [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ] || return 0
         return 1
         ;;
      *) return 1 ;;
   esac
}
# Create secure_hive in Ranger and apply scripts/secure-ranger-admin-default-and-owner.sh (idempotent).
function ensureSecureRangerHiveBootstrap(){
   local namespace="${1:-secure}"
   local bootstrap_script="${HIVECTL_ROOT}/scripts/secure-ranger-bootstrap-hive.sh"

   case "${namespace}" in secure|warehouse) ;; *) return 0 ;; esac
   if secureRangerHiveBootstrapDisabled; then
      return 0
   fi
   overlayActive "secure_ranger" || return 0
   rangerPodRunningAndReady "${namespace}" || return 0
   if [ ! -x "${bootstrap_script}" ]; then
      echo "Warning: missing ${bootstrap_script}; skip Ranger Hive bootstrap"
      return 0
   fi
   echo "Ranger Hive bootstrap: secure_hive service + lab admin policies ..."
   if ! "${bootstrap_script}" "${namespace}"; then
      echo "Warning: Ranger Hive bootstrap failed (HS2 auth may deny until secure_hive exists in Admin)"
      return 1
   fi
   echo "Ranger Hive bootstrap done (HS2 plugin poll ~30s; restart HS2 if policies seem stale)"
   return 0
}
function ensureRangerPortForward(){
   local namespace="${1:-secure}"
   local port=""
   local pidfile=""
   local pid=""

   if rangerPortForwardDisabled; then
      stopRangerPortForward "${namespace}"
      echo "Ranger port-forward disabled (HIVECTL_RANGER_PORT_FORWARD=${HIVECTL_RANGER_PORT_FORWARD})"
      return 0
   fi

   if ! kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   port="$(rangerLocalPort)"
   pidfile="$(rangerPortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if rangerLocalUrlReachable "${port}"; then
      if [ -f "${pidfile}" ]; then
         pid="$(cat "${pidfile}")"
         if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (port-forward pid ${pid})"
         else
            echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (already reachable; not starting port-forward)"
         fi
      else
         echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (already reachable; not starting port-forward)"
      fi
      rangerAdminPasswordHint "${namespace}"
      startRangerPortForwardMonitor "${namespace}" || true
      return 0
   fi

   if startRangerPortForwardProcess "${namespace}"; then
      pid="$(cat "${pidfile}")"
      echo "Ranger Admin (${namespace}): http://localhost:${port}/login.jsp (hiveCtl port-forward pid ${pid}; stops on './hiveCtl.sh stop ${namespace} ranger')"
      rangerAdminPasswordHint "${namespace}"
      startRangerPortForwardMonitor "${namespace}" || true
      return 0
   fi
   echo "Warning: could not bind localhost:${port} for Ranger. Try: kubectl port-forward svc/ranger -n ${namespace} ${port}:6080" >&2
   rangerAdminPasswordHint "${namespace}"
   startRangerPortForwardMonitor "${namespace}" || true
   return 1
}
function llapDaemonPortForwardPidFile(){
   local namespace="${1:-llap}"
   echo "$(hiveCtlStateDir)/${namespace}-llap-daemon-portforward.pid"
}
function llapDaemonLocalPort(){
   echo "${HIVECTL_LLAP_DAEMON_LOCAL_PORT:-15002}"
}
function stopLlapDaemonPortForward(){
   local namespace="${1:-llap}"
   local pidfile=""
   local pid=""

   pidfile="$(llapDaemonPortForwardPidFile "${namespace}")"
   [ -f "${pidfile}" ] || return 0
   pid="$(cat "${pidfile}")"
   if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
   fi
   rm -f "${pidfile}"
}
# Expose llapdaemon-0 web UI on localhost:15002 (HIVECTL_LLAP_DAEMON_PORT_FORWARD=0 to disable).
function ensureLlapDaemonPortForward(){
   local namespace="${1:-llap}"
   local port=""
   local mode=""
   local pidfile=""
   local pid=""
   local code=""

   mode="${HIVECTL_LLAP_DAEMON_PORT_FORWARD:-auto}"
   case "${mode}" in
      0|false|no|off|disable|disabled)
         echo "LLAP daemon UI port-forward disabled (HIVECTL_LLAP_DAEMON_PORT_FORWARD=${mode})"
         return 0
         ;;
   esac

   if ! kubectl get pod llapdaemon-0 -n "${namespace}" >/dev/null 2>&1; then
      return 0
   fi

   port="$(llapDaemonLocalPort)"
   pidfile="$(llapDaemonPortForwardPidFile "${namespace}")"
   mkdir -p "$(hiveCtlStateDir)"

   if [ -f "${pidfile}" ]; then
      pid="$(cat "${pidfile}")"
      if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
         echo "LLAP daemon UI (${namespace}): http://localhost:${port}/ (llapdaemon-0 port-forward pid ${pid})"
         return 0
      fi
      rm -f "${pidfile}"
   fi

   if command -v curl >/dev/null 2>&1; then
      code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" --connect-timeout 2 2>/dev/null || echo 000)"
      case "${code}" in
         200|301|302|303|401|403|404)
            echo "LLAP daemon UI: http://localhost:${port}/ (already reachable; not starting port-forward)"
            return 0
            ;;
      esac
   fi

   if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"${port}" -sTCP:LISTEN -t >/dev/null 2>&1; then
      echo "LLAP daemon UI: http://localhost:${port}/ (port ${port} in use — manual port-forward?)"
      return 0
   fi

   nohup kubectl port-forward "pod/llapdaemon-0" -n "${namespace}" "${port}:15002" >/dev/null 2>&1 &
   pid=$!
   echo "${pid}" > "${pidfile}"
   sleep 1
   if kill -0 "${pid}" 2>/dev/null; then
      echo "LLAP daemon UI (${namespace}): http://localhost:${port}/ (llapdaemon-0; pid ${pid}; stops on './hiveCtl.sh stop ${namespace} llapdaemon' or 'stop ${namespace}')"
      return 0
   fi
   rm -f "${pidfile}"
   echo "Warning: could not bind localhost:${port} for LLAP daemon UI. Try: kubectl port-forward pod/llapdaemon-0 -n ${namespace} ${port}:15002" >&2
   return 1
}
# Summarize node CPU arch for llap (Hive pods auto-tune hive.llap.io.enabled at bootstrap).
function llapNodeArchSummary(){
   local archs=""

   archs="$(kubectl get nodes -l node-role.kubernetes.io/llap -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{" "}{end}' 2>/dev/null | xargs echo)"
   if [ -z "${archs}" ]; then
      archs="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{" "}{end}' 2>/dev/null | xargs echo)"
   fi
   if [ -n "${archs}" ]; then
      echo "LLAP worker node architecture(s): ${archs} (hive.llap.io.enabled is set per pod via hadoop checknative in staging.sh)"
   fi
}
# Percent of /var used on a Kind node container (empty when unknown).
function kindNodeVarUsePercent(){
   local node="$1"

   docker exec "${node}" df -P /var 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}
function pruneKindNodeImages(){
   local node="$1"

   docker exec "${node}" crictl rmi --prune 2>/dev/null
}
# Kind cluster name for "kind load" (Docker Desktop cluster is often "desktop", not "kind").
function kindClusterName(){
   local name="${HIVECTL_KIND_CLUSTER_NAME:-${KIND_CLUSTER:-}}"
   local node=""
   local clusters=""

   if [ -n "${name}" ]; then
      printf '%s\n' "${name}"
      return 0
   fi
   if command -v kind >/dev/null 2>&1; then
      clusters="$(kind get clusters 2>/dev/null || true)"
      if [ "$(printf '%s\n' "${clusters}" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ]; then
         printf '%s\n' "${clusters}" | sed '/^$/d' | head -1
         return 0
      fi
   fi
   node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 1
   case "${node}" in
      *-control-plane)
         printf '%s\n' "${node%-control-plane}"
         return 0
         ;;
   esac
   return 1
}
# Copy a locally built image into every Kind node (avoids docker.io pull for custom tags).
function ensureKindLocalImage(){
   local image="$1"
   local cluster=""

   case "${HIVECTL_KIND_LOAD:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
   esac
   command -v docker >/dev/null 2>&1 || return 0
   command -v kind >/dev/null 2>&1 || return 0
   if ! docker image inspect "${image}" >/dev/null 2>&1; then
      echo "hiveCtl: local Docker image not found: ${image}" >&2
      echo "hiveCtl: build it first (see docker/hive-ranger/README.md), or set HIVE_RANGER_IMAGE to a pullable tag." >&2
      return 1
   fi
   cluster="$(kindClusterName)" || {
      echo "hiveCtl: skip kind load for ${image} (Kind cluster name unknown; set HIVECTL_KIND_CLUSTER_NAME)" >&2
      return 0
   }
   echo "hiveCtl: kind load docker-image ${image} --name ${cluster}"
   kind load docker-image "${image}" --name "${cluster}" || return 1
}
function ensureSecureRangerHs2KindImage(){
   [ "${HIVECTL_SECURE_RANGER_HS2:-0}" = "1" ] || return 0
   ensureKindLocalImage "${HIVE_RANGER_IMAGE:-hive-on-k8s/hive-ranger:2.4.0-nightly}"
}
# LLAP daemons schedule onto nodes labeled node-role.kubernetes.io/llap (EC2/Cloudera: label worker nodes first).
# Warn (do not block) when no labeled node exists, so a missing label is visible instead of silently Pending.
function warnIfNoLlapNodes(){
   local count=""
   count="$(kubectl get nodes -l node-role.kubernetes.io/llap --no-headers 2>/dev/null | wc -l | tr -d ' ')"
   if [ "${count:-0}" = "0" ]; then
      # Label every non-control-plane node as an LLAP worker so llapdaemon pods can schedule.
      echo "No node labeled node-role.kubernetes.io/llap; labeling worker nodes."
      kubectl get nodes --no-headers 2>/dev/null \
         | awk '$3 !~ /control-plane/ {print $1}' \
         | while read -r node; do
              kubectl label node "${node}" node-role.kubernetes.io/llap= --overwrite >/dev/null 2>&1 \
                 && echo "  labeled ${node}"
           done
   fi
}
# Warehouse Cassandra image (4.1.12 + Instaclustr Kerberos authenticator); built from docker/cassandra-kerberos.
function ensureWarehouseCassandraKindImage(){
   ensureKindLocalImage "${HIVE_CASSANDRA_IMAGE:-hive-on-k8s/cassandra-kerberos:4.1.12}"
}
function reportKindNodeDisk(){
   local node="$1"
   local use=""

   use="$(kindNodeVarUsePercent "${node}")"
   [ -n "${use}" ] || return 1
   echo "${node} /var ${use}% used"
}
# Download the standalone kustomize CLI into HIVECTL_BIN_DIR when it is not on PATH.
function installLocalKustomize(){
   local bin="${HIVECTL_BIN_DIR}/kustomize"
   local version="${HIVECTL_KUSTOMIZE_VERSION:-}"
   local install_args=()

   mkdir -p "${HIVECTL_BIN_DIR}" || return 1
   if [ -x "${bin}" ]; then
      return 0
   fi
   case "${HIVECTL_KUSTOMIZE_INSTALL:-1}" in
      0|false|no|off|disable|disabled)
         echo "hiveCtl: kustomize is not on PATH and HIVECTL_KUSTOMIZE_INSTALL=0" >&2
         return 1
         ;;
   esac
   if ! command -v curl >/dev/null 2>&1; then
      echo "hiveCtl: curl is required to download kustomize into ${HIVECTL_BIN_DIR}" >&2
      return 1
   fi
   echo "hiveCtl: kustomize not found — installing into ${HIVECTL_BIN_DIR} ..."
   if [ -n "${version}" ]; then
      install_args=( "${version}" "${HIVECTL_BIN_DIR}" )
   else
      install_args=( "${HIVECTL_BIN_DIR}" )
   fi
   curl -sL "${HIVECTL_KUSTOMIZE_INSTALL_URL}" | bash -s -- "${install_args[@]}" || return 1
   chmod +x "${bin}" 2>/dev/null || true
   if [ ! -x "${bin}" ]; then
      echo "hiveCtl: kustomize install did not create executable ${bin}" >&2
      return 1
   fi
   echo "hiveCtl: kustomize ready ($("${bin}" version -s 2>/dev/null || "${bin}" version 2>/dev/null | head -1))"
}
# Require kubectl and the standalone kustomize CLI before building overlays.
function requireHostDeployTools(){
   if ! command -v kubectl >/dev/null 2>&1; then
      echo "hiveCtl: kubectl is not on PATH (required)" >&2
      return 1
   fi
   if command -v kustomize >/dev/null 2>&1; then
      return 0
   fi
   installLocalKustomize || return 1
   command -v kustomize >/dev/null 2>&1
}
function requireHostDeployToolsOnce(){
   [ "${HIVECTL_HOST_TOOLS_CHECKED:-0}" = "1" ] && return 0
   HIVECTL_HOST_TOOLS_CHECKED=1
   requireHostDeployTools
}
# Return 0 when the Hive StorageClass uses rancher.io/local-path with reclaimPolicy Retain.
function hiveLocalPathStorageClassReady(){
   local provisioner=""
   local reclaim=""
   local sc="${HIVE_STORAGE_CLASS_NAME}"

   kubectl get storageclass "${sc}" >/dev/null 2>&1 || return 1
   provisioner="$(kubectl get storageclass "${sc}" -o jsonpath='{.provisioner}' 2>/dev/null)"
   reclaim="$(kubectl get storageclass "${sc}" -o jsonpath='{.reclaimPolicy}' 2>/dev/null)"
   [ "${provisioner}" = "rancher.io/local-path" ] && [ "${reclaim}" = "Retain" ]
}
# Create the Hive StorageClass backed by the Rancher local-path provisioner (Retain).
function applyHiveLocalPathStorageClass(){
   local sc="${HIVE_STORAGE_CLASS_NAME}"

   kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
}
# Ensure local-path-provisioner is running and the Hive StorageClass is ready for PVCs.
function ensureHiveLocalPathStorageClass(){
   local provisioner=""
   local reclaim=""
   local sc="${HIVE_STORAGE_CLASS_NAME}"

   case "${HIVECTL_STORAGE_CHECK:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
   esac

   if ! kubectl get storageclass >/dev/null 2>&1; then
      echo "hiveCtl: kubectl cluster not reachable (cannot verify StorageClass ${sc})" >&2
      return 1
   fi

   if hiveLocalPathStorageClassReady; then
      return 0
   fi

   if kubectl get storageclass "${sc}" >/dev/null 2>&1; then
      provisioner="$(kubectl get storageclass "${sc}" -o jsonpath='{.provisioner}' 2>/dev/null)"
      reclaim="$(kubectl get storageclass "${sc}" -o jsonpath='{.reclaimPolicy}' 2>/dev/null)"
      echo "hiveCtl: StorageClass '${sc}' exists but is provisioner='${provisioner}' reclaimPolicy='${reclaim}'" >&2
      echo "hiveCtl: expected provisioner rancher.io/local-path and reclaimPolicy Retain (delete the class, then retry start)" >&2
      return 1
   fi

   echo "hiveCtl: StorageClass '${sc}' (rancher.io/local-path, Retain) not found — installing local-path-provisioner ..."
   kubectl apply -f "${HIVECTL_LOCAL_PATH_STORAGE_URL}" || return 1
   if kubectl get deployment local-path-provisioner -n local-path-storage >/dev/null 2>&1; then
      kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=180s >/dev/null || {
         echo "hiveCtl: local-path-provisioner deployment did not become ready" >&2
         return 1
      }
   fi

   applyHiveLocalPathStorageClass || return 1

   if hiveLocalPathStorageClassReady; then
      echo "hiveCtl: StorageClass '${sc}' is ready (rancher.io/local-path, Retain)"
      return 0
   fi
   echo "hiveCtl: StorageClass '${sc}' still not ready after install" >&2
   return 1
}
function ensureHiveLocalPathStorageClassOnce(){
   [ "${HIVECTL_STORAGE_CHECKED:-0}" = "1" ] && return 0
   HIVECTL_STORAGE_CHECKED=1
   ensureHiveLocalPathStorageClass
}
# Prune unused containerd images on Kind nodes when /var is nearly full (avoids ImagePullBackOff).
function ensureClusterDiskSpace(){
   local max_use=""
   local node=""
   local use=""
   local use_after=""

   case "${HIVECTL_DISK_CHECK:-1}" in
      0|false|no|off|disable|disabled) return 0 ;;
   esac
   command -v docker >/dev/null 2>&1 || return 0
   kubectl get nodes >/dev/null 2>&1 || return 0

   max_use="${HIVECTL_DISK_MAX_USE_PERCENT:-90}"

   while read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      use="$(kindNodeVarUsePercent "${node}")"
      [ -n "${use}" ] || continue
      if [ "${use}" -lt "${max_use}" ]; then
         continue
      fi
      echo "hiveCtl: ${node} /var is ${use}% full (threshold ${max_use}%) — pruning unused container images ..."
      pruneKindNodeImages "${node}"
      use_after="$(kindNodeVarUsePercent "${node}")"
      if [ -n "${use_after}" ]; then
         echo "hiveCtl: ${node} /var now ${use_after}% used"
      fi
      if [ -n "${use_after}" ] && [ "${use_after}" -ge 98 ]; then
         echo "Warning: ${node} still critically full (${use_after}%). Try: ./hiveCtl.sh disk   or increase Docker Desktop disk." >&2
      fi
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
}
function ensureClusterDiskSpaceOnce(){
   [ "${HIVECTL_DISK_CHECKED:-0}" = "1" ] && return 0
   HIVECTL_DISK_CHECKED=1
   ensureClusterDiskSpace
}
function ensureDeployPrerequisitesOnce(){
   requireHostDeployToolsOnce || return 1
   ensureClusterDiskSpaceOnce
   ensureHiveLocalPathStorageClassOnce || return 1
}
# Delete every synced query log on HDFS (/user/hive/logs) and the local caches that would upload them again.
function pruneHdfsQueryLogs(){
   local namespace=""
   local pod=""
   local hive_pod=""

   for namespace in llap secure mini; do
      kubectl get namespace "${namespace}" >/dev/null 2>&1 || continue
      pod="$(hdfsBackupPod "${namespace}")"
      if ! kubectl get pod "${pod}" -n "${namespace}" >/dev/null 2>&1; then
         echo "hiveCtl: ${namespace} has no ${pod}; skipping HDFS log prune"
         continue
      fi
      echo "hiveCtl: deleting /user/hive/logs in ${namespace} ..."
      if [ "${namespace}" = "secure" ]; then
         kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
            realm="${KRB5_REALM:-SECURE.LAB}"
            host="$(hostname -f)"
            sudo -u hadoop kinit -kt /home/hadoop/host-service.keytab "hdfs/${host}@${realm}" || exit 1
            err="$(hdfs dfs -test -e /user/hive/logs 2>&1)" || {
               if printf "%s" "${err}" | grep -q "Connection refused\\|Could not connect\\|StandbyException"; then
                  printf "%s\n" "${err}" >&2
                  exit 1
               fi
               echo "no /user/hive/logs"
               exit 0
            }
            hdfs dfs -rm -r -skipTrash /user/hive/logs
         ' || echo "hiveCtl: HDFS log prune failed in ${namespace}" >&2
      else
         kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
            err="$(hdfs dfs -test -e /user/hive/logs 2>&1)" || {
               if printf "%s" "${err}" | grep -q "Connection refused\\|Could not connect\\|StandbyException"; then
                  printf "%s\n" "${err}" >&2
                  exit 1
               fi
               echo "no /user/hive/logs"
               exit 0
            }
            hdfs dfs -rm -r -skipTrash /user/hive/logs
         ' || echo "hiveCtl: HDFS log prune failed in ${namespace}" >&2
      fi
      while read -r hive_pod; do
         [ -n "${hive_pod}" ] || continue
         kubectl exec "${hive_pod}" -n "${namespace}" -- bash -lc 'rm -rf /opt/hive/log/tez /opt/hive/log/llap' >/dev/null 2>&1 || true
      done < <(kubectl get pods -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^(hiveserver2-|llapdaemon-|hivemetastore-)' || true)
   done
}
function showClusterDisk(){
   local node=""
   local any=0

   command -v docker >/dev/null 2>&1 || { echo "docker not available"; return 1; }
   kubectl get nodes >/dev/null 2>&1 || { echo "kubectl cluster not reachable"; return 1; }
   echo "hiveCtl: Kind node disk before HDFS log prune"
   while read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      reportKindNodeDisk "${node}" && any=1
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
   [ "${any}" -eq 1 ] || echo "No Kind node containers matched cluster node names"
   pruneHdfsQueryLogs
   echo "hiveCtl: Kind node disk after HDFS log prune"
   any=0
   while read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      reportKindNodeDisk "${node}" && any=1
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
   ensureClusterDiskSpace
}
# Start all components in dependency order.
function startStack(){
   local namespace="$1"
   local component=""
   local components=()

   ensureDeployPrerequisitesOnce || return 1

   case "${namespace}" in
      standalone)
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         components=(mysql hive hue)
         ;;
      mini)
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         components=(hadoop mysql hivemetastore hiveserver2 hue)
         ;;
      llap)
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         llapNodeArchSummary
         components=(hadoop mysql zookeeper hivemetastore llapdaemon hiveserver2 hue)
         ;;
      secure)
         ensureKrb5Secrets "${namespace}" || return 1
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         llapNodeArchSummary
         components=(krb5kdc hadoop-namenode mysql)
         if [ "${HIVECTL_SECURE_RANGER:-0}" = "1" ]; then
            components+=(ranger)
         fi
         components+=(zookeeper hivemetastore llapdaemon hiveserver2 hue)
         ;;
      warehouse)
         # Startup order: KDC -> ZooKeeper/Hadoop -> Cassandra ring + trino DC -> MySQL/Postgres/Oracle -> Ranger -> HMS -> LLAP -> HS2 -> Impala -> Trino -> Hue
         ensureKrb5Secrets "${namespace}" || return 1
         ensureHueSecrets "${namespace}" || return 1
         ensureAdminSecrets "${namespace}" || return 1
         components=(krb5kdc zookeeper hadoop-namenode cassandra cassandra-trino mysql postgres oracle)
         if [ "${HIVECTL_WAREHOUSE_RANGER:-1}" = "1" ]; then
            components+=(ranger)
         fi
         components+=(hivemetastore llapdaemon hiveserver2 impala trino hue)
         ;;
      *)
         components=(hadoop mysql hivemetastore hiveserver2)
         ;;
   esac

   for component in "${components[@]}"; do
      startOverlay "${namespace}_${component}" || return 1
   done
   ensureProfileUiPortForwards "${namespace}" || true
}
# Refresh Hue port-forwards for every profile that still has hue-0 (avoids stale single-port 8888).
function ensureHuePortForwardsForActiveProfiles(){
   local ns=""

   for ns in standalone mini llap secure warehouse; do
      profileHasHue "${ns}" || continue
      kubectl get namespace "${ns}" >/dev/null 2>&1 || continue
      kubectl get svc hue -n "${ns}" >/dev/null 2>&1 || continue
      ensureHuePortForward "${ns}" || true
   done
}
# Start or refresh localhost port-forwards for Hue / Ranger after full stack or restore.
function ensureProfileUiPortForwards(){
   local namespace="$1"

   if [ "${namespace}" = "secure" ]; then
      if kubectl get svc ranger -n "${namespace}" >/dev/null 2>&1; then
         ensureRangerPortForward "${namespace}" || true
      fi
   fi
   ensureHuePortForwardsForActiveProfiles
   ensureHs2PortForwardsForActiveProfiles
}
# Stop all components in reverse dependency order.
function stopStack(){
   local namespace="$1"
   local component=""
   local components=()

   requireNamespace "${namespace}" || return 1

   case "${namespace}" in
      standalone)
         components=(hue hive mysql)
         ;;
      mini)
         components=(hue hiveserver2 hivemetastore mysql hadoop)
         ;;
      llap)
         components=(hue hiveserver2 llapdaemon hivemetastore zookeeper mysql hadoop)
         ;;
      secure)
         components=(hue hiveserver2 llapdaemon hivemetastore zookeeper)
         overlayActive "secure_ranger"
         if [ $? -eq 0 ]; then
            components+=(ranger)
         fi
         components+=(mysql hadoop-namenode krb5kdc)
         ;;
      warehouse)
         # Reverse of startStack: Hue -> Trino -> Impala -> HS2 -> LLAP -> HMS -> Ranger -> Oracle/Postgres/MySQL -> Cassandra -> Hadoop/ZK -> KDC
         components=(hue trino impala hiveserver2 llapdaemon hivemetastore)
         overlayActive "warehouse_ranger"
         if [ $? -eq 0 ]; then
            components+=(ranger)
         fi
         components+=(oracle postgres mysql cassandra-trino cassandra hadoop-namenode zookeeper krb5kdc)
         ;;
      *)
         components=(hiveserver2 hivemetastore mysql hadoop)
         ;;
   esac

   for component in "${components[@]}"; do
      stopOverlay "${namespace}_${component}" || return 1
   done
}
# Ensure a required component is active and Ready.
function ensureOverlayReady(){
   local namespace="$1"
   local service="$2"
   local target="${namespace}_${service}"

   overlayActive "${target}"
   case $? in
      0) waitForReady "${namespace}" "${service}" ;;
      1)
         echo "Overlay: ${target} must be active"
         return 1
         ;;
      *) return 1 ;;
   esac
}
# Stop Hive writer services and report which ones were stopped.
function stopHiveWriters(){
   local namespace="$1"
   local stopped_hms_var="$2"
   local stopped_hs2_var="$3"
   local hms_was_stopped=0
   local hs2_was_stopped=0

   overlayActive "${namespace}_hiveserver2"
   case $? in
      0)
         stopOverlay "${namespace}_hiveserver2" || return 1
         hs2_was_stopped=1
         ;;
      2) return 1 ;;
   esac
   overlayActive "${namespace}_hivemetastore"
   case $? in
      0)
         stopOverlay "${namespace}_hivemetastore" || return 1
         hms_was_stopped=1
         ;;
      2) return 1 ;;
   esac

   printf -v "${stopped_hms_var}" "%s" "${hms_was_stopped}"
   printf -v "${stopped_hs2_var}" "%s" "${hs2_was_stopped}"
}
# Restart Hive writer services that were stopped earlier.
function restartHiveWriters(){
   local namespace="$1"
   local stopped_hms="$2"
   local stopped_hs2="$3"
   local status=0

   if [ "${stopped_hms}" = "1" ]; then
      startOverlay "${namespace}_hivemetastore" || status=1
   fi
   if [ "${stopped_hs2}" = "1" ]; then
      startOverlay "${namespace}_hiveserver2" || status=1
   fi

   return "${status}"
}
# Create a temporary pod that mounts standalone data PVCs for offline backup/restore.
function createStandaloneDataHelper(){
   local namespace="$1"

   cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: standalone-data-helper
  namespace: ${namespace}
spec:
  serviceAccountName: hive
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: helper
      image: apache/hive:4.2.0
      command: ["/bin/bash", "-lc", "sleep infinity"]
      volumeMounts:
        - name: derby
          mountPath: /opt/hive/derby
        - name: warehouse
          mountPath: /opt/hive/data/warehouse
        - name: logs
          mountPath: /opt/hive/log
  volumes:
    - name: derby
      persistentVolumeClaim:
        claimName: pvc-derby
    - name: warehouse
      persistentVolumeClaim:
        claimName: pvc-warehouse
    - name: logs
      persistentVolumeClaim:
        claimName: pvc-logs
EOF
   kubectl wait --for=condition=Ready pod/standalone-data-helper -n "${namespace}" --timeout=180s
}
# Delete the temporary standalone data helper pod.
function deleteStandaloneDataHelper(){
   local namespace="$1"

   kubectl delete pod standalone-data-helper -n "${namespace}" --ignore-not-found --force
}
# Restore standalone Derby, warehouse, and log PVC contents.
function restoreStandaloneStack(){
   local namespace="$1"
   local backup_dir="$2"
   local was_active=0
   local names=""
   local status=0

   if [ -z "${backup_dir}" ]; then
      echo "Restore requires a backup directory"
      return 1
   fi
   if [ ! -f "${backup_dir}/standalone-hive.tgz" ]; then
      echo "Backup directory must contain standalone-hive.tgz"
      return 1
   fi

   ensureDeployPrerequisitesOnce || return 1

   restoreSecrets "${namespace}" "${backup_dir}" || return 1
   echo "Restoring standalone backup from: ${backup_dir}"

   # The data helper mounts the overlay's PVCs, which only exist once the overlay has been started
   names="$(kubectlNames pvc pvc-derby -n "${namespace}")" || return 1
   if [ -z "${names}" ]; then
      startOverlay "${namespace}_hive" || return 1
   fi
   overlayActive "${namespace}_hive"
   case $? in
      0)
         stopOverlay "${namespace}_hive" || return 1
         was_active=1
         ;;
      2) return 1 ;;
   esac

   createStandaloneDataHelper "${namespace}" || status=1
   if [ "${status}" -eq 0 ]; then
      kubectl cp "${backup_dir}/standalone-hive.tgz" "${namespace}/standalone-data-helper:/tmp/standalone-hive.tgz" || status=1
   fi
   if [ "${status}" -eq 0 ]; then
      kubectl exec standalone-data-helper -n "${namespace}" -- bash -lc '
         find /opt/hive/derby -mindepth 1 -exec rm -rf {} +
         find /opt/hive/data/warehouse -mindepth 1 -exec rm -rf {} +
         find /opt/hive/log -mindepth 1 -exec rm -rf {} +
         tar -C /opt/hive -xzf /tmp/standalone-hive.tgz
         chown -R 1000:1000 /opt/hive/derby /opt/hive/data/warehouse /opt/hive/log 2>/dev/null || true
      ' || status=1
   fi

   deleteStandaloneDataHelper "${namespace}" || status=1

   if [ "${was_active}" = "1" ]; then
      startOverlay "${namespace}_hive" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Standalone restore complete: ${backup_dir}"
   else
      echo "Standalone restore failed: ${backup_dir}"
   fi
   return "${status}"
}
# List existing backup directories for an overlay (./backups/<overlay>-YYYYMMDD-HHMMSS),
# newest first, so the user can decide whether a new backup is needed.
function listBackupsForOverlay(){
   local namespace="$1"
   local dir=""
   local found=0

   echo "Available previous backups for '${namespace}':"
   for dir in $(ls -1d ./backups/"${namespace}"-*/ 2>/dev/null | sort -r); do
      dir="${dir%/}"
      local files=""
      files="$(ls -1 "${dir}" 2>/dev/null | tr '\n' ' ')"
      echo "  - ${dir}  [${files% }]"
      found=1
   done
   if [ "${found}" -eq 0 ]; then
      echo "  (none found under ./backups/)"
   fi
   echo
}

# Destructively remove standalone data PVC/PV bindings after optional backup.
function cleanupStandaloneStack(){
   local namespace="$1"
   local answer=""
   local confirm=""
   local status=0

   requireNamespace "${namespace}" || return 1

   cat <<EOF
WARNING: cleanup will delete standalone PVCs for namespace '${namespace}'.

Typical PVCs:
  - pvc-derby
  - pvc-warehouse
  - pvc-logs
  - mysql-mysql-0 (Hue DB when Hue is enabled)

Cleanup removes every PVC in the namespace, every PV bound to it, and
/var/local-path-provisioner/pvc-*_${namespace}_* on Kind nodes (same as secure).

If these PVCs/PVs are cleared, standalone Derby metastore, warehouse, and logs can be lost.
EOF

   listBackupsForOverlay "${namespace}"
   read -r -p "Create a backup before cleanup? [Y/n] " answer
   case "${answer}" in
      ""|y|Y|yes|YES)
         backupStack "${namespace}" || return 1
         ;;
      n|N|no|NO)
         echo "Skipping backup."
         ;;
      *)
         echo "Invalid answer. Aborting cleanup."
         return 1
         ;;
   esac

   echo
   read -r -p "Type '${namespace}' to confirm PVC/PV cleanup: " confirm
   if [ "${confirm}" != "${namespace}" ]; then
      echo "Confirmation did not match. Aborting cleanup."
      return 1
   fi

   stopStack "${namespace}" || return 1

   deleteNamespaceStorageAndLocalPath "${namespace}" || status=1

   echo "Deleting namespace '${namespace}' ..."
   kubectl delete namespace "${namespace}" --ignore-not-found || status=1
   waitForDeleted 300 "namespace/${namespace}" || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Standalone cleanup complete. Run './hiveCtl.sh start ${namespace}' to recreate the namespace and empty PVCs."
   else
      echo "Standalone cleanup finished with errors. Inspect PVC/PV state before restarting."
   fi
   return "${status}"
}
# Pod used for offline HDFS backup/restore (mini/llap vs secure NameNode).
function hdfsBackupPod(){
   case "${1:-}" in
      secure) echo "hadoop-namenode-0" ;;
      *) echo "hadoop-0" ;;
   esac
}
# Restore HDFS paths from an archive inside the HDFS admin pod.
function hdfsRestoreFromArchive(){
   local namespace="$1"
   local pod
   pod="$(hdfsBackupPod "${namespace}")"

   if [ "${namespace}" = "secure" ]; then
      # shellcheck disable=SC2016
      kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
         realm="${KRB5_REALM:-SECURE.LAB}"
         host="$(hostname -f)"
         sudo -u hadoop kinit -kt /home/hadoop/host-service.keytab "hdfs/${host}@${realm}" || exit 1
         rm -rf /tmp/hdfs-restore
         mkdir -p /tmp/hdfs-restore
         tar -C /tmp/hdfs-restore -xzf /tmp/hdfs-backup.tgz
         for path in /opt /tmp /user /users /warehouse; do
            hdfs dfs -rm -r -skipTrash "${path}" >/dev/null 2>&1 || true
         done
         for path in /tmp/hdfs-restore/hdfs-backup/*; do
            hdfs dfs -put "${path}" /
         done
         hdfs dfs -mkdir -p /tmp/hive /user/hive /user/admin /warehouse/tablespace/managed/hive /warehouse/tablespace/external/hive
         hdfs dfs -chmod 777 / /tmp
         hdfs dfs -chmod -R 777 /tmp/hive
         hdfs dfs -chown -R hive:supergroup /tmp/hive /user/hive /warehouse /opt || true
         hdfs dfs -chown admin:supergroup /user/admin 2>/dev/null || true
      '
   else
      # shellcheck disable=SC2016
      kubectl exec "${pod}" -n "${namespace}" -- bash -lc '
         rm -rf /tmp/hdfs-restore
         mkdir -p /tmp/hdfs-restore
         tar -C /tmp/hdfs-restore -xzf /tmp/hdfs-backup.tgz
         for path in /opt /tmp /user /users /warehouse; do
            hdfs dfs -rm -r -skipTrash "${path}" >/dev/null 2>&1 || true
         done
         for path in /tmp/hdfs-restore/hdfs-backup/*; do
            hdfs dfs -put "${path}" /
         done
         hdfs dfs -mkdir -p /tmp/hive /user/hive /user/admin /warehouse/tablespace/managed/hive /warehouse/tablespace/external/hive
         hdfs dfs -chmod 777 / /tmp
         hdfs dfs -chmod -R 777 /tmp/hive
         hdfs dfs -chown -R hive:supergroup /tmp/hive /user/hive /warehouse /opt || true
         hdfs dfs -chown admin:supergroup /user/admin 2>/dev/null || true
      '
   fi
}
# Clusters without Kind/docker: remove the namespace's local-path dirs with a short-lived pod on each node.
function cleanupLocalPathDirsWithPods(){
   local namespace="$1"
   local base=""
   local node=""
   local pod=""

   base="$(kubectl get configmap local-path-config -n local-path-storage -o jsonpath='{.data.config\.json}' 2>/dev/null \
      | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["nodePathMap"][0]["paths"][0])
except Exception:
    print("/opt/local-path-provisioner")')"
   echo "Removing local-path data for namespace '${namespace}' under ${base} on every node ..."
   for node in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
      pod="local-path-clean-$(printf '%s' "${node}" | cksum | cut -d' ' -f1)"
      cat <<EOF | kubectl apply -f - >/dev/null || continue
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: local-path-storage
spec:
  nodeName: ${node}
  restartPolicy: Never
  automountServiceAccountToken: false
  tolerations:
    - operator: Exists
  containers:
    - name: clean
      image: $(pvcHelperImage)
      command: ["sh", "-c", "for d in /base/pvc-*_${namespace}_*; do [ -d \"\$d\" ] || continue; echo \"${node}: removed \$d (\$(du -sh \"\$d\" | cut -f1))\"; rm -rf \"\$d\"; done"]
      securityContext:
        runAsUser: 0
      volumeMounts:
        - name: base
          mountPath: /base
  volumes:
    - name: base
      hostPath:
        path: ${base}
        type: DirectoryOrCreate
EOF
   done
   for node in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
      pod="local-path-clean-$(printf '%s' "${node}" | cksum | cut -d' ' -f1)"
      kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod}" -n local-path-storage --timeout=180s >/dev/null 2>&1
      kubectl logs "${pod}" -n local-path-storage 2>/dev/null | sed "s|/base/|${base}/|"
      kubectl delete pod "${pod}" -n local-path-storage --now --ignore-not-found >/dev/null
   done
}
# Delete orphaned local-path-provisioner dirs on Kind nodes (Retain PVs leave data on disk).
function cleanupLocalPathProvisionerDirs(){
   local namespace="$1"
   local node=""
   local line=""
   local path=""
   local size=""

   [ -n "${namespace}" ] || return 0
   if ! command -v docker >/dev/null 2>&1; then
      cleanupLocalPathDirsWithPods "${namespace}"
      return 0
   fi
   if ! kubectl get nodes >/dev/null 2>&1; then
      echo "kubectl cannot list nodes; skipping stale local-path-provisioner cleanup"
      return 0
   fi

   echo "Removing stale local-path-provisioner data for namespace '${namespace}' on Kind nodes ..."
   while IFS= read -r node; do
      [ -n "${node}" ] || continue
      docker inspect "${node}" >/dev/null 2>&1 || continue
      while IFS= read -r line; do
         [ -n "${line}" ] || continue
         path="${line#*|}"
         size="${line%%|*}"
         echo "  ${node}: removed ${path} (${size})"
      done < <(
         docker exec "${node}" bash -lc "
            shopt -s nullglob
            for d in /var/local-path-provisioner/pvc-*_${namespace}_*; do
               [ -d \"\${d}\" ] || continue
               sz=\$(du -sh \"\${d}\" 2>/dev/null | awk '{print \$1}')
               echo \"\${sz}|\${d}\"
               rm -rf \"\${d}\"
            done
         " 2>/dev/null || true
      )
   done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

   return 0
}
# Typical PVC names per profile (cleanup also removes any other PVCs still in the namespace).
function stackCleanupPvcsExpected(){
   case "${1:-}" in
      secure)
         echo "mysql-mysql-0 pvc-hdfs-nn datanode-data-hadoop-datanode-0 datanode-data-hadoop-datanode-1 datanode-data-hadoop-datanode-2 krb5kdc-data-krb5kdc-0"
         ;;
      mini|llap)
         echo "mysql-mysql-0 pvc-hdfs"
         ;;
      standalone)
         echo "pvc-derby pvc-warehouse pvc-logs"
         ;;
      *)
         echo "mysql-mysql-0 pvc-hdfs"
         ;;
   esac
}
function pvcNamesInNamespace(){
   local namespace="$1"

   kubectl get pvc -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null
}
function pvNamesForNamespace(){
   local namespace="$1"

   kubectl get pv -o custom-columns=NAME:.metadata.name,NS:.spec.claimRef.namespace --no-headers 2>/dev/null \
      | awk -v ns="${namespace}" '$2 == ns { print $1 }'
}
# Delete every PVC in the namespace, every PV bound to it, and local-path dirs on Kind nodes.
function deleteNamespaceStorageAndLocalPath(){
   local namespace="$1"
   local status=0
   local pvc_list=""
   local pv_names=""
   local pv=""
   local pvc=""
   local wait_args=()

   pvc_list="$(pvcNamesInNamespace "${namespace}")"
   pv_names="$(pvNamesForNamespace "${namespace}")"

   if [ -n "${pvc_list// /}" ]; then
      echo "Deleting PVCs in namespace '${namespace}' ..."
      # shellcheck disable=SC2086
      kubectl delete pvc ${pvc_list} -n "${namespace}" --ignore-not-found || status=1
   else
      echo "No PVCs remain in namespace '${namespace}'."
   fi

   if [ -n "${pv_names}" ]; then
      echo "Deleting PV objects bound to namespace '${namespace}' ..."
      while IFS= read -r pv; do
         [ -n "${pv}" ] || continue
         kubectl delete pv "${pv}" --ignore-not-found || status=1
      done <<< "${pv_names}"
   fi

   wait_args=()
   for pvc in ${pvc_list}; do
      wait_args+=( "pvc/${pvc}" )
   done
   if [ "${#wait_args[@]}" -gt 0 ]; then
      waitForDeleted 180 "${wait_args[@]}" -n "${namespace}" || status=1
   fi

   cleanupLocalPathProvisionerDirs "${namespace}" || true
   return "${status}"
}
# Return 0 when MySQL in the namespace contains the given database.
function mysqlDatabaseExists(){
   local namespace="$1"
   local db="$2"

   kubectl exec mysql-0 -n "${namespace}" -- \
      sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SHOW DATABASES"' 2>/dev/null \
      | grep -qx "${db}"
}
# Stop Ranger Admin during backup/restore so the policy database is quiescent (secure only).
function stopRangerIfActive(){
   local namespace="$1"
   local stopped_var="$2"
   local stopped=0

   printf -v "${stopped_var}" "0"
   [ "${namespace}" = "secure" ] || return 0
   overlayActive "secure_ranger"
   case $? in
      0)
         stopOverlay "secure_ranger" || return 1
         stopped=1
         ;;
      1|2) ;;
   esac
   printf -v "${stopped_var}" "${stopped}"
   return 0
}
# Start Ranger Admin after backup/restore when it was stopped for MySQL consistency.
function startRangerIfStopped(){
   local namespace="$1"
   local was_stopped="$2"

   [ "${was_stopped}" = "1" ] || return 0
   [ "${namespace}" = "secure" ] || return 0
   startOverlay "secure_ranger" || return 1
}
# Create ranger DB/user on mysql-0 before importing mysql-ranger.sql (fresh PVC after cleanup).
function ensureRangerMysqlForRestore(){
   local namespace="$1"
   local backup_dir="$2"
   local ranger_db_pw=""

   [ "${namespace}" = "secure" ] || return 0
   [ -f "${backup_dir}/mysql-ranger.sql" ] || return 0
   ensureSecrets "${namespace}" || return 1
   ranger_db_pw="$(kubectl get secret hive-credentials -n "${namespace}" -o jsonpath='{.data.ranger-db-password}' 2>/dev/null | base64 -d 2>/dev/null)" || true
   if [ -z "${ranger_db_pw}" ]; then
      echo "Cannot restore Ranger policies: ranger-db-password missing in hive-credentials"
      return 1
   fi
   echo "Ensuring Ranger MySQL database/user before policy restore ..."
   # shellcheck disable=SC2016
   kubectl exec mysql-0 -n "${namespace}" -- \
      env RANGER_DB_PASSWORD="${ranger_db_pw}" \
      sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS ranger CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '\''rangeradmin'\''@'\''%'\'' IDENTIFIED WITH mysql_native_password BY '\''${RANGER_DB_PASSWORD}'\'';
ALTER USER '\''rangeradmin'\''@'\''%'\'' IDENTIFIED WITH mysql_native_password BY '\''${RANGER_DB_PASSWORD}'\'';
GRANT ALL PRIVILEGES ON ranger.* TO '\''rangeradmin'\''@'\''%'\'';
FLUSH PRIVILEGES;
EOF' || return 1
}
# Restore Ranger policies from mysql-ranger.sql when present in the backup directory.
function restoreRangerDatabase(){
   local namespace="$1"
   local backup_dir="$2"

   [ "${namespace}" = "secure" ] || return 0
   if [ ! -f "${backup_dir}/mysql-ranger.sql" ]; then
      echo "No mysql-ranger.sql in backup (Ranger policies were not included)"
      return 0
   fi
   ensureRangerMysqlForRestore "${namespace}" "${backup_dir}" || return 1
   echo "Restoring MySQL ranger database (Ranger policies and services) ..."
   # shellcheck disable=SC2016
   kubectl exec -i mysql-0 -n "${namespace}" -- \
      sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
      < "${backup_dir}/mysql-ranger.sql" || return 1
}
# Full-namespace backup: every Secret, the workload/Service/ConfigMap manifests, the replica count of each
# StatefulSet/Deployment, and the file contents of every bound PVC (copied while the workloads are scaled
# to zero, so databases, the KDC, Cassandra and Oracle are captured consistently).
function pvcHelperImage(){
   echo "${HIVECTL_PVC_HELPER_IMAGE:-busybox:1.36}"
}
function pvcHelperPodName(){
   echo "pvc-helper-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}
# Start a root pod that mounts one PVC at /data. affinity is an optional "key=value" node label the
# scheduler should prefer, so a new volume is provisioned where the original one lived.
function createPvcHelper(){
   local namespace="$1"
   local pvc="$2"
   local affinity="${3:-}"
   local pod=""
   local affinity_yaml=""

   pod="$(pvcHelperPodName "${pvc}")"
   if [ -n "${affinity}" ]; then
      affinity_yaml="  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: ${affinity%%=*}
                operator: In
                values: [\"${affinity#*=}\"]"
   fi
   cat <<EOF | kubectl apply -f - >/dev/null || return 1
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${namespace}
  labels:
    app: pvc-helper
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
${affinity_yaml}
  containers:
    - name: helper
      image: $(pvcHelperImage)
      command: ["sh", "-c", "sleep 86400"]
      securityContext:
        runAsUser: 0
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${pvc}
EOF
   kubectl wait --for=condition=Ready "pod/${pod}" -n "${namespace}" --timeout=600s >/dev/null
}
function deletePvcHelper(){
   kubectl delete pod "$(pvcHelperPodName "$2")" -n "$1" --ignore-not-found --now >/dev/null
}
# Print "kind/name replicas" for every StatefulSet and Deployment in the namespace.
function namespaceWorkloads(){
   kubectl get statefulsets,deployments -n "$1" -o json \
   | python3 -c 'import json, sys
for o in json.load(sys.stdin)["items"]:
    print("%s/%s %s" % (o["kind"].lower(), o["metadata"]["name"], o["spec"].get("replicas", 1)))'
}
# Scale every workload to zero and wait until no pod still mounts a PVC.
function quiesceNamespaceWorkloads(){
   local namespace="$1"
   local workload=""
   local deadline=$((SECONDS + 900))

   for workload in $(kubectl get statefulsets,deployments -n "${namespace}" -o name); do
      kubectl scale "${workload}" -n "${namespace}" --replicas=0 >/dev/null || return 1
   done
   echo "Waiting for pods in '${namespace}' to stop ..."
   while kubectl get pods -n "${namespace}" -o json | python3 -c 'import json, sys
busy = [p for p in json.load(sys.stdin)["items"]
        if p["metadata"].get("labels", {}).get("app") != "pvc-helper"
        and p["status"].get("phase") not in ("Succeeded", "Failed")
        and any("persistentVolumeClaim" in v for v in p["spec"].get("volumes", []))]
sys.exit(0 if busy else 1)'; do
      if [ "${SECONDS}" -ge "${deadline}" ]; then
         echo "Timed out waiting for pods in '${namespace}' to stop"
         return 1
      fi
      sleep 5
   done
}
# Scale workloads listed in a "kind/name replicas" file back to their recorded count, then wait for them.
function scaleNamespaceWorkloads(){
   local namespace="$1"
   local workloads_file="$2"
   local workload=""
   local replicas=""
   local status=0

   while read -r workload replicas; do
      [ -n "${workload}" ] || continue
      kubectl get "${workload}" -n "${namespace}" >/dev/null 2>&1 || continue
      kubectl scale "${workload}" -n "${namespace}" --replicas="${replicas}" >/dev/null || status=1
   done < "${workloads_file}"
   while read -r workload replicas; do
      [ -n "${workload}" ] && [ "${replicas}" != "0" ] || continue
      kubectl get "${workload}" -n "${namespace}" >/dev/null 2>&1 || continue
      kubectl rollout status "${workload}" -n "${namespace}" --timeout=1200s || status=1
   done < "${workloads_file}"
   return "${status}"
}
# Strip cluster-assigned fields so exported objects can be re-created in a new namespace.
function portableObjectList(){
   python3 -c 'import json, sys
drop_annotations = ("kubectl.kubernetes.io/last-applied-configuration", "deployment.kubernetes.io/revision")
items = []
for o in json.load(sys.stdin)["items"]:
    m = o["metadata"]
    kind = o["kind"]
    if m.get("ownerReferences") or m.get("labels", {}).get("app") == "pvc-helper":
        continue
    if kind == "ConfigMap" and m["name"] == "kube-root-ca.crt":
        continue
    if kind == "ServiceAccount" and m["name"] == "default":
        continue
    if kind == "Secret" and o.get("type") in ("kubernetes.io/service-account-token", "helm.sh/release.v1"):
        continue
    meta = {"name": m["name"], "namespace": m["namespace"]}
    for field in ("labels", "annotations"):
        values = {k: v for k, v in m.get(field, {}).items() if k not in drop_annotations}
        if values:
            meta[field] = values
    o["metadata"] = meta
    o.pop("status", None)
    if kind == "Service":
        o["spec"].pop("clusterIPs", None)
        if o["spec"].get("clusterIP") != "None":
            o["spec"].pop("clusterIP", None)
    if kind == "ServiceAccount":
        o.pop("secrets", None)
    items.append(o)
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=1))'
}
# Print "name storageClass size accessMode nodeLabel=value" for every bound PVC in the namespace.
function namespacePvcInventory(){
   local namespace="$1"

   python3 -c 'import json, subprocess, sys
ns = sys.argv[1]
pvcs = json.loads(subprocess.check_output(["kubectl", "get", "pvc", "-n", ns, "-o", "json"]))["items"]
pvs = {p["metadata"]["name"]: p for p in json.loads(subprocess.check_output(["kubectl", "get", "pv", "-o", "json"]))["items"]}
for c in pvcs:
    if c.get("status", {}).get("phase") != "Bound":
        continue
    affinity = "-"
    terms = pvs.get(c["spec"].get("volumeName"), {}).get("spec", {}).get("nodeAffinity", {}).get("required", {}).get("nodeSelectorTerms", [])
    for term in terms:
        for expr in term.get("matchExpressions", []):
            if expr.get("operator") == "In" and expr.get("values"):
                affinity = "%s=%s" % (expr["key"], expr["values"][0])
                break
    print(c["metadata"]["name"], c["spec"].get("storageClassName") or "-",
          c["status"].get("capacity", {}).get("storage") or c["spec"]["resources"]["requests"]["storage"],
          c["spec"]["accessModes"][0], affinity)' "${namespace}"
}
function backupStack(){
   local namespace="$1"
   local backup_dir="${2:-}"
   local pvc=""
   local status=0

   if [ -z "${backup_dir}" ]; then
      backup_dir="./backups/${namespace}-$(date +%Y%m%d-%H%M%S)"
   fi

   requireNamespace "${namespace}" || return 1
   ensureDeployPrerequisitesOnce || return 1

   mkdir -p "${backup_dir}/pvc" || return 1
   chmod 700 "${backup_dir}" || return 1
   echo "Creating backup in: ${backup_dir}"

   kubectl get secrets -n "${namespace}" -o json | portableObjectList > "${backup_dir}/secrets.json" || return 1
   kubectl get statefulsets,deployments,services,configmaps,serviceaccounts,roles,rolebindings -n "${namespace}" -o json \
      | portableObjectList > "${backup_dir}/manifests.json" || return 1
   namespaceWorkloads "${namespace}" > "${backup_dir}/workloads.txt" || return 1
   activeOverlays | awk -v ns="${namespace}" -F_ '$1 == ns' | sort -u > "${backup_dir}/overlays.txt" || return 1
   namespacePvcInventory "${namespace}" > "${backup_dir}/pvcs.txt" || return 1

   quiesceNamespaceWorkloads "${namespace}" || status=1

   if [ "${status}" -eq 0 ]; then
      while read -r pvc _; do
         [ -n "${pvc}" ] || continue
         echo "Backing up PVC ${pvc} ..."
         if ! createPvcHelper "${namespace}" "${pvc}" \
            || ! kubectl exec "$(pvcHelperPodName "${pvc}")" -n "${namespace}" -- \
                 tar --numeric-owner -C /data -czf - . > "${backup_dir}/pvc/${pvc}.tgz"; then
            echo "Failed to back up PVC ${pvc}"
            status=1
         fi
         deletePvcHelper "${namespace}" "${pvc}"
         [ "${status}" -eq 0 ] || break
      done < "${backup_dir}/pvcs.txt"
   fi

   echo "Starting workloads in '${namespace}' again ..."
   scaleNamespaceWorkloads "${namespace}" "${backup_dir}/workloads.txt" || status=1
   ensureProfileUiPortForwards "${namespace}" || true

   if [ "${status}" -eq 0 ]; then
      echo "Backup complete: ${backup_dir}"
   else
      echo "Backup failed: ${backup_dir}"
   fi
   return "${status}"
}
# StorageClass for a re-created PVC: a StatefulSet volume uses its volumeClaimTemplate's class (none means
# the cluster default), other PVCs their recorded class. HIVE_STORAGE_CLASS_NAME replaces the repo default.
function pvcRestoreStorageClass(){
   python3 -c 'import json, sys
backup_dir, pvc, recorded, default_sc, override = sys.argv[1:6]
sc = recorded
for o in json.load(open(backup_dir + "/manifests.json"))["items"]:
    if o["kind"] != "StatefulSet":
        continue
    for t in o["spec"].get("volumeClaimTemplates", []):
        prefix = "%s-%s-" % (t["metadata"]["name"], o["metadata"]["name"])
        if pvc.startswith(prefix) and pvc[len(prefix):].isdigit():
            sc = t["spec"].get("storageClassName") or "-"
if sc == default_sc and override:
    sc = override
print(sc)' "$1" "$2" "$3" "hive-on-k8s-local-path" "${HIVE_STORAGE_CLASS_NAME:-}"
}
# Restore a full-namespace backup: Secrets, PVC contents, then the stack, every overlay and object that was
# running, and the recorded replica counts. Works on a live namespace, after cleanup, or on a new cluster.
function restoreFullStack(){
   local namespace="$1"
   local backup_dir="$2"
   local pvc=""
   local storage_class=""
   local size=""
   local access_mode=""
   local affinity=""
   local target=""
   local status=0

   ensureDeployPrerequisitesOnce || return 1
   ensureNamespace "${namespace}" || return 1
   echo "Restoring backup from: ${backup_dir}"

   quiesceNamespaceWorkloads "${namespace}" || return 1

   echo "Restoring Secrets ..."
   kubectl apply -f "${backup_dir}/secrets.json" >/dev/null || return 1

   while read -r pvc storage_class size access_mode affinity; do
      [ -n "${pvc}" ] || continue
      if [ ! -f "${backup_dir}/pvc/${pvc}.tgz" ]; then
         echo "Missing ${backup_dir}/pvc/${pvc}.tgz"
         return 1
      fi
      if ! kubectl get pvc "${pvc}" -n "${namespace}" >/dev/null 2>&1; then
         storage_class="$(pvcRestoreStorageClass "${backup_dir}" "${pvc}" "${storage_class}")"
         cat <<EOF | kubectl apply -f - >/dev/null || return 1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${namespace}
spec:
  accessModes: ["${access_mode}"]
$( [ "${storage_class}" != "-" ] && echo "  storageClassName: ${storage_class}" )
  resources:
    requests:
      storage: ${size}
EOF
      fi
      echo "Restoring PVC ${pvc} ..."
      [ "${affinity}" = "-" ] && affinity=""
      if ! createPvcHelper "${namespace}" "${pvc}" "${affinity}" \
         || ! kubectl exec -i "$(pvcHelperPodName "${pvc}")" -n "${namespace}" -- \
              sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar --numeric-owner -C /data -xzpf -' \
              < "${backup_dir}/pvc/${pvc}.tgz"; then
         echo "Failed to restore PVC ${pvc}"
         status=1
      fi
      deletePvcHelper "${namespace}" "${pvc}"
      [ "${status}" -eq 0 ] || return 1
   done < "${backup_dir}/pvcs.txt"

   # The backed-up manifests are what was running, including image overrides given at start time
   # (RANGER_ADMIN_IMAGE, HIVE_IMAGE_REGISTRY, ...) and objects applied outside an overlay.
   echo "Re-creating workloads, Services and ConfigMaps from the backup ..."
   kubectl apply -f "${backup_dir}/manifests.json" >/dev/null || status=1
   # Workloads that weren't running at backup time stay stopped.
   for target in $(kubectl get statefulsets,deployments -n "${namespace}" -o name); do
      grep -q "^${target/.apps/} " "${backup_dir}/workloads.txt" \
         || kubectl scale "${target}" -n "${namespace}" --replicas=0 >/dev/null || status=1
   done
   scaleNamespaceWorkloads "${namespace}" "${backup_dir}/workloads.txt" || status=1
   ensureProfileUiPortForwards "${namespace}" || true

   if [ "${status}" -eq 0 ]; then
      echo "Restore complete: ${backup_dir}"
   else
      echo "Restore failed: ${backup_dir}"
   fi
   return "${status}"
}
function restoreStack(){
   local namespace="$1"
   local backup_dir="$2"

   if [ -z "${backup_dir}" ] || [ ! -d "${backup_dir}" ]; then
      echo "Restore requires a backup directory"
      return 1
   fi
   if [ -f "${backup_dir}/pvcs.txt" ]; then
      restoreFullStack "${namespace}" "${backup_dir}"
   elif [ -f "${backup_dir}/standalone-hive.tgz" ]; then
      restoreStandaloneStack "${namespace}" "${backup_dir}"
   else
      restoreLegacyStack "${namespace}" "${backup_dir}"
   fi
}
# Restore an older backup (mysql-hive.sql + hdfs-backup.tgz, from before full-namespace backups).
function restoreLegacyStack(){
   local namespace="$1"
   local backup_dir="$2"
   local stopped_hms=0
   local stopped_hs2=0
   local stopped_ranger=0
   local started_storage=0
   local component=""
   local status=0

   if [ ! -f "${backup_dir}/mysql-hive.sql" ] || [ ! -f "${backup_dir}/hdfs-backup.tgz" ]; then
      echo "Backup directory must contain mysql-hive.sql and hdfs-backup.tgz"
      return 1
   fi

   ensureDeployPrerequisitesOnce || return 1

   restoreSecrets "${namespace}" "${backup_dir}" || return 1

   echo "Restoring backup from: ${backup_dir}"
   stopHiveWriters "${namespace}" stopped_hms stopped_hs2 || return 1
   stopRangerIfActive "${namespace}" stopped_ranger || return 1

   # Storage that isn't running is started now and the rest of the stack after the restore,
   # so on a fresh namespace the Metastore never creates an empty schema first
   local storage_components=()
   case "${namespace}" in
      secure) storage_components=(krb5kdc hadoop-namenode mysql) ;;
      *) storage_components=(hadoop mysql) ;;
   esac
   for component in "${storage_components[@]}"; do
      overlayActive "${namespace}_${component}"
      case $? in
         0)
            if [ "${component}" = "hadoop-namenode" ]; then
               waitForReady "${namespace}" "hadoop-datanode" || status=1
            fi
            waitForReady "${namespace}" "${component}" || status=1
            ;;
         1)
            startOverlay "${namespace}_${component}" || status=1
            started_storage=1
            ;;
         *) status=1 ;;
      esac
   done

   if [ "${status}" -eq 0 ]; then
      echo "Restoring MySQL metastore database ..."
      # shellcheck disable=SC2016
      kubectl exec -i mysql-0 -n "${namespace}" -- \
         sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
         < "${backup_dir}/mysql-hive.sql" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      restoreRangerDatabase "${namespace}" "${backup_dir}" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      echo "Restoring HDFS data ..."
      local hdfs_pod
      hdfs_pod="$(hdfsBackupPod "${namespace}")"
      kubectl cp "${backup_dir}/hdfs-backup.tgz" "${namespace}/${hdfs_pod}:/tmp/hdfs-backup.tgz" || status=1
   fi

   if [ "${status}" -eq 0 ]; then
      hdfsRestoreFromArchive "${namespace}" || status=1
   fi

   if [ "${started_storage}" = "0" ]; then
      startRangerIfStopped "${namespace}" "${stopped_ranger}" || status=1
      restartHiveWriters "${namespace}" "${stopped_hms}" "${stopped_hs2}" || status=1
   elif [ "${status}" -eq 0 ]; then
      startStack "${namespace}" || status=1
      startRangerIfStopped "${namespace}" "${stopped_ranger}" || status=1
   fi

   ensureProfileUiPortForwards "${namespace}" || true
   if [ "${status}" -eq 0 ]; then
      echo "Restore complete: ${backup_dir}"
   else
      echo "Restore failed: ${backup_dir}"
   fi
   return "${status}"
}
# Destructively remove stack data PVC/PV bindings after optional backup.
function cleanupStack(){
   local namespace="$1"
   local answer=""
   local confirm=""
   local status=0
   local expected_pvcs=""
   local actual_pvcs=""

   if [ "${namespace}" = "standalone" ]; then
      cleanupStandaloneStack "${namespace}"
      return $?
   fi

   requireNamespace "${namespace}" || return 1

   expected_pvcs="$(stackCleanupPvcsExpected "${namespace}")"
   actual_pvcs="$(pvcNamesInNamespace "${namespace}")"

   cat <<EOF
WARNING: cleanup will delete PVCs for namespace '${namespace}'.

Typical PVCs for this profile:
$(for pvc in ${expected_pvcs}; do echo "  - ${pvc}"; done)

Cleanup removes every PVC still in the namespace and every PV bound to it
(same as secure), then stale local-path data on Kind nodes.
$(if [ -n "${actual_pvcs// /}" ] && [ "${actual_pvcs}" != "${expected_pvcs}" ]; then
     echo "PVCs currently present: ${actual_pvcs}"
   fi)

If these PVCs/PVs are cleared, Hive metastore and HDFS data can be lost.
EOF

   listBackupsForOverlay "${namespace}"
   read -r -p "Create a backup before cleanup? [Y/n] " answer
   case "${answer}" in
      ""|y|Y|yes|YES)
         backupStack "${namespace}" || return 1
         ;;
      n|N|no|NO)
         echo "Skipping backup."
         ;;
      *)
         echo "Invalid answer. Aborting cleanup."
         return 1
         ;;
   esac

   echo
   read -r -p "Type '${namespace}' to confirm PVC/PV cleanup: " confirm
   if [ "${confirm}" != "${namespace}" ]; then
      echo "Confirmation did not match. Aborting cleanup."
      return 1
   fi

   stopStack "${namespace}" || return 1

   deleteNamespaceStorageAndLocalPath "${namespace}" || status=1

   echo "Deleting namespace '${namespace}' ..."
   kubectl delete namespace "${namespace}" --ignore-not-found || status=1
   waitForDeleted 300 "namespace/${namespace}" || status=1

   if [ "${status}" -eq 0 ]; then
      echo "Cleanup complete. Run './hiveCtl.sh start ${namespace}' to recreate the namespace and empty PVCs."
   else
      echo "Cleanup finished with errors. Inspect PVC/PV state before restarting."
   fi
   return "${status}"
}

# Overlays that use hive-credentials (namespace name = overlay name).
function passwdOverlayName(){
   case "${1:-}" in
      mini|llap|secure|standalone|warehouse) echo "${1}" ;;
      *) return 1 ;;
   esac
}
# Secret data key for a passwd alias (empty if unknown).
function passwdSecretKeyForAlias(){
   case "${1:-}" in
      mysql-root) echo "mysql-root-password" ;;
      hive-mysql) echo "hive-metastore-password" ;;
      hue-mysql) echo "hue-mysql-password" ;;
      hue-admin) echo "hue-admin-password" ;;
      hue-secret-key) echo "hue-secret-key" ;;
      ranger-admin) echo "ranger-admin-password" ;;
      ranger-db) echo "ranger-db-password" ;;
      krb5-master) echo "krb5-master-password" ;;
      krb5-kadmin) echo "krb5-kadmin-password" ;;
      root) echo "root-password" ;;
      hive) echo "hive-password" ;;
      hadoop) echo "hadoop-password" ;;
      beeline) echo "beeline-password" ;;
      admin) echo "admin-password" ;;
      *) return 1 ;;
   esac
}
# passwd aliases applicable to an overlay profile (may not exist in Secret until ensure* runs).
function passwdAliasesForOverlay(){
   local overlay="$1"
   case "${overlay}" in
      secure|warehouse)
         echo "mysql-root hive-mysql hue-admin hue-mysql hue-secret-key ranger-admin ranger-db krb5-master krb5-kadmin root hive hadoop beeline admin"
         ;;
      standalone|llap|mini)
         echo "mysql-root hive-mysql hue-admin hue-mysql hue-secret-key root hive hadoop beeline admin"
         ;;
      *)
         return 1
         ;;
   esac
}
function listPasswd(){
   local overlay="${1:-}"
   local alias=""
   local key=""
   local desc=""
   local present=""

   if [ -z "${overlay}" ]; then
      echo "Password aliases (hive-credentials Secret; namespace = overlay name):"
      echo ""
      printf "%-16s %-28s %s\n" "ALIAS" "SECRET_KEY" "DESCRIPTION"
      printf "%-16s %-28s %s\n" "-----" "----------" "-----------"
      while read -r alias key desc; do
         [ -n "${alias}" ] || continue
         printf "%-16s %-28s %s\n" "${alias}" "${key}" "${desc}"
      done <<'EOF'
mysql-root mysql-root-password MySQL root
hive-mysql hive-metastore-password MySQL hive metastore user
hue-admin hue-admin-password Hue UI user admin
hue-mysql hue-mysql-password Hue MySQL user
hue-secret-key hue-secret-key Hue Django secret (not a login password)
ranger-admin ranger-admin-password Ranger UI user admin
ranger-db ranger-db-password MySQL rangeradmin (Ranger schema)
krb5-master krb5-master-password KDC database master (secure)
krb5-kadmin krb5-kadmin-password kadmin principal (secure)
root root-password Lab bootstrap root slot
hive hive-password Lab Hive service / JDBC material
hadoop hadoop-password Lab Hadoop service material
beeline beeline-password Beeline JDBC (often same as hive at create)
admin admin-password Lab admin slot (not the Hue or Ranger UI login)
EOF
      echo ""
      echo "Profiles:"
      echo "  secure, warehouse: mysql-root hive-mysql hue-admin hue-mysql hue-secret-key ranger-admin ranger-db krb5-master krb5-kadmin root hive hadoop beeline admin"
      echo "  standalone, mini, llap: mysql-root hive-mysql hue-admin hue-mysql hue-secret-key root hive hadoop beeline admin"
      echo ""
      echo "List keys present in a cluster:  hiveCtl list passwd <overlay>"
      return 0
   fi

   passwdOverlayName "${overlay}" >/dev/null || {
      echo "Unknown overlay '${overlay}' (use mini, llap, secure, standalone, or warehouse)"
      return 1
   }
   requireNamespace "${overlay}" || return 1
   if ! kubectl get secret hive-credentials -n "${overlay}" >/dev/null 2>&1; then
      echo "Secret hive-credentials not found in namespace '${overlay}' (start the overlay first)"
      return 1
   fi

   echo "Password aliases in hive-credentials (namespace ${overlay}):"
   printf "%-16s %-28s %s\n" "ALIAS" "SECRET_KEY" "IN_SECRET"
   for alias in $(passwdAliasesForOverlay "${overlay}"); do
      key="$(passwdSecretKeyForAlias "${alias}")" || continue
      present="$(kubectl get secret hive-credentials -n "${overlay}" -o "jsonpath={.data.${key}}" 2>/dev/null)"
      if [ -n "${present}" ]; then
         present="yes"
      else
         present="no"
      fi
      printf "%-16s %-28s %s\n" "${alias}" "${key}" "${present}"
   done
}
function getPasswd(){
   local overlay=""
   local alias=""
   local key=""
   local value=""

   if passwdOverlayName "${1:-}" >/dev/null 2>&1; then
      overlay="${1}"
      alias="${2:-}"
   else
      overlay="${HIVECTL_PASSWD_OVERLAY:-secure}"
      alias="${1:-}"
   fi

   if [ -z "${alias}" ]; then
      echo "Usage: hiveCtl get passwd [<overlay>] <alias>   (hiveCtl list passwd for aliases)"
      return 1
   fi
   passwdOverlayName "${overlay}" >/dev/null || {
      echo "Unknown overlay '${overlay}'"
      return 1
   }
   key="$(passwdSecretKeyForAlias "${alias}")" || {
      echo "Unknown password alias '${alias}' (try: hiveCtl list passwd)"
      return 1
   }
   requireNamespace "${overlay}" || return 1
   if ! kubectl get secret hive-credentials -n "${overlay}" >/dev/null 2>&1; then
      echo "Secret hive-credentials not found in namespace '${overlay}'"
      return 1
   fi
   value="$(kubectl get secret hive-credentials -n "${overlay}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null)"
   if [ -z "${value}" ]; then
      echo "Key '${key}' (${alias}) is not set in hive-credentials (namespace ${overlay})"
      return 1
   fi
   printf '%s\n' "${value}"
}

# Dispatch CLI actions to the appropriate helper.
main(){
   case "${1:-}" in
        __hue-portforward-monitor)
          huePortForwardMonitorLoop
          ;;
        __ranger-portforward-monitor)
          rangerPortForwardMonitorLoop
          ;;
        available)
          overlays
          ;;
        start)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             startStack "$2"
          else
             startOverlay "$2_$3"
          fi
          ;;
        stop)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             stopStack "$2"
          else
             stopOverlay  "$2_$3"
          fi
          ;;
        status)
          activeOverlays show
          ;;
        disk)
          showClusterDisk
          ;;
        resync-keytabs)
          [[ -z "${2:-}" ]] && help && exit 1
          HIVECTL_KRB5_RESYNC_KEYTABS=1 ensureKerberosKeytabSecret "$2" || exit 1
          echo "Updated Secret kerberos-keytabs in namespace '${2}'."
          if [ "$2" = "secure" ]; then
             echo "Restarting Hadoop + Hive so pods remount v3 keytabs (FQDN + pod short name) ..."
             stopOverlay "secure_hiveserver2" || true
             stopOverlay "secure_hivemetastore" || true
             stopSecureHadoop || exit 1
             startSecureHadoop || exit 1
             startOverlay "secure_hivemetastore" || exit 1
             startOverlay "secure_hiveserver2" || exit 1
          else
             echo "Restart Kerberos-enabled pods in '${2}' to remount keytabs."
          fi
          ;;
        restart)
          [[ -z "${2:-}" ]] && help && exit 1
          if [ -z "${3:-}" ]; then
             stopStack "$2" && startStack "$2"
          else
             stopOverlay "$2_$3" && startOverlay "$2_$3"
          fi
          ;;
        backup)
          [[ -z "${2:-}" ]] && help && exit 1
          backupStack "$2" "${3:-}"
          ;;
        restore)
          [[ -z "${2:-}" || -z "${3:-}" ]] && help && exit 1
          restoreStack "$2" "$3"
          ;;
        cleanup)
          [[ -z "${2:-}" ]] && help && exit 1
          cleanupStack "$2"
          ;;
        list)
          case "${2:-}" in
             passwd) listPasswd "${3:-}" ;;
             *) help && exit 1 ;;
          esac
          ;;
        get)
          case "${2:-}" in
             passwd) getPasswd "${3:-}" "${4:-}" ;;
             *) help && exit 1 ;;
          esac
          ;;
        *)
          help
          ;;
esac
}

main "$@"
