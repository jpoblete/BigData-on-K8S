# Warehouse profile

> Usage Notice: This project is not meant for commercial use without permission and proper credit.
> Author: j.martinez.poblete@gmail.com

The `warehouse` profile is a Kerberos-secured data warehouse in the `warehouse` namespace, realm `WAREHOUSE.LAB`. It builds on the [`secure`](secure-profile.md) Hive stack and adds **Cassandra**, **Trino**, and **Impala**, all queryable from **Hue**.

> **Resource warning:** `warehouse` is memory heavy. It requests ~7 CPU and ~31 GiB RAM (limits ~67 GiB) and uses ~20.6 GiB at idle. Run it on a real cluster with 48 GiB+ of Kubernetes memory for meaningful testing; it does not fit a kind / Docker Desktop lab on a laptop. In our tests the `llap` profile runs fine on kind. Full sizing: [README hardware requirements](../README.md#hardware-requirements).

## Components

| Layer | Component | Image / source |
|-------|-----------|----------------|
| KDC | MIT Kerberos | `debian:bookworm-slim` (overlay `overlays/warehouse/krb5kdc`, host list `warehouse-hosts.list`) |
| HDFS | 1 NameNode + 3 DataNodes, `dfs.replication=3` | `apache/hadoop:3.4.1` |
| ZooKeeper | SASL/Kerberos | overlay `overlays/warehouse/zookeeper` |
| Cassandra (Kerberos ring) | 3 nodes, Kerberos-only auth | `jpoblete73/cassandra-kerberos:4.1.12` (custom, amd64 + arm64, see below) |
| Cassandra (`trino` DC) | 1 node (`cassandra-trino`), password auth + mTLS, read by Trino | `jpoblete73/cassandra-kerberos:4.1.12` (overlay `overlays/warehouse/cassandra-trino`) |
| MySQL | Hive metastore + Ranger DB, plus `bigdata` database for Trino | `mysql:8.4` (overlay `overlays/warehouse/mysql`) |
| PostgreSQL | `bigdata` database (schema `bigdata`) for Trino | `postgres:16` (component `components/postgres`) |
| Oracle | `bigdata` for Trino (user/schema `bigdata`, quoted in SQL) | `container-registry.oracle.com/database/free:23.9.0.0-amd64` (23ai Free, component `components/oracle`) |

Trino database catalogs (MySQL, PostgreSQL, Oracle) and their setup are in [trino-database-catalogs.md](trino-database-catalogs.md).
Backup, restore, cleanup, and live-cluster notes are in [operations-notes.md](operations-notes.md).

### Image sources (portability)

Every image the warehouse namespace runs is public or hosted in this repo's Docker Hub account, so the stack deploys to another cluster without logins:

| Image | Source |
| --- | --- |
| `apache/hadoop:3.4.1`, `apache/hive:nightly`, `gethue/hue:latest`, `mysql:8.4`, `postgres:16`, `trinodb/trino:484`, `zookeeper:3.8`, `debian:bookworm-slim` | Public upstream (Docker Hub) |
| `jpoblete73/cassandra-kerberos:4.1.12` | Docker Hub (this repo's account); multi-arch amd64 + arm64 |
| `jpoblete73/ranger:2.4.0` | Docker Hub multi-arch tag: upstream `apache/ranger:2.4.0` (arm64, the only platform upstream publishes for 2.4.0) + `jpoblete73/ranger:2.4.0-amd64` built from `docker/ranger-admin` |
| `jpoblete73/oracle-free:23.9.0.0-amd64` | Docker Hub copy of Oracle's `container-registry.oracle.com/database/free:23.9.0.0-amd64` |

Oracle's original registry requires a login and license acceptance, which is why the copy is hosted here.
| Ranger | Admin (Hive policies) | overlay `overlays/warehouse/ranger` |
| Hive | Metastore + HiveServer2 (Kerberos), LLAP | `apache/hive:nightly` |
| Trino | 1 coordinator + 2 workers, Trino 484 | `trinodb/trino:484` |
| Impala | statestored + catalogd + 3 impalad (one per DataNode node), Impala 4.5.3 | `apache/impala:4.5.3-statestored`, `jpoblete73/impala:4.5.3-{catalogd,impalad_coord_exec}-hive4` (custom, see below; overlay `overlays/warehouse/impala`, amd64 only) |
| Hue | Hive + Trino interpreters | `hive-on-k8s/hue-trino` (custom, see below) |

## Startup and shutdown order

Startup: KDC → ZooKeeper / Hadoop (1 NN + 3 DN) → Cassandra ring → Cassandra `trino` DC → MySQL → PostgreSQL → Oracle → Ranger → Hive Metastore → LLAP → HiveServer2 → Impala → Trino → Hue.

On start, `hiveCtl.sh` also provisions what used to be manual: the Trino database passwords in `hive-credentials`, each database's `bigdata` schema and `trino` user (`components/*/setup/apply-bigdata-schema.sh`, idempotent), and the Cassandra `trino` DC (internal CA, server and Trino client keystores, the `trino@WAREHOUSE.LAB` superuser role, `trino` replication on every keyspace, and `nodetool rebuild` when replication was added). Existing Secrets and data are kept.
Shutdown is the reverse.

```bash
./hiveCtl.sh start warehouse
./hiveCtl.sh stop warehouse
```

## Custom images

These are our own builds. Each Dockerfile or source file carries an in-file label stating whether it is original or a modification of upstream.

### `hive-on-k8s/cassandra-kerberos:4.1.12` (`docker/cassandra-kerberos`)

Cassandra 4.1.12 with the Kerberos SASL authenticator. Built from `authenticator-src/` (Maven reactor: `base` + `cassandra-4.1`, shaded into one jar).

- `base/.../BaseKerberosAuthenticator.java`: **unmodified** upstream (Instaclustr `cassandra-kerberos` v4.1.0-1.0.0).
- `cassandra-4.1/.../KerberosAuthenticator.java`: **modified** — the role lookup passes `Dispatcher.RequestTime.forImmediateExecution()` instead of `System.nanoTime()`, required by Cassandra 4.1.12 (the upstream 4.1.0 jar fails with `NoSuchMethodError` on `SelectStatement.execute`).
- `docker-entrypoint-krb5.sh`: verifies reverse DNS, writes the Kerberos properties, runs `kinit` for the `cassandra` service principal.
- `cql-krb.py`: a GSSAPI CQL client that canonicalises peer IPs to FQDNs so the principal matches the KDC.

The unused upstream jar `cassandra-kerberos-4.1.0-1.0.0.jar` is kept out of the image; it is not referenced by the build.

### `jpoblete73/impala:4.5.3-*-hive4` (`docker/impala-hive4`)

`apache/impala:4.5.3-catalogd` and `-impalad_coord_exec` with one class replaced in `impala-frontend`: `org.apache.impala.compat.MetastoreShim` (**modified** from the 4.5.3 tag). The upstream images are built against Cloudera Hive and reject any table whose metastore `accessType` is unset; Hive 4 leaves it unset unless the client sends processor capabilities, which catalogd's table load does not. The patched class treats unset as `READWRITE`; tables the metastore does mark keep their value. ACID and bucketing checks are unchanged.

```bash
for role in catalogd impalad_coord_exec; do
  docker buildx build --platform linux/amd64 --build-arg ROLE=$role \
    -t jpoblete73/impala:4.5.3-$role-hive4 --push docker/impala-hive4
done
```

### `hive-on-k8s/hue-trino` (`docker/hue-trino`)

`gethue/hue:latest` bundles SQLAlchemy 1.3.8, which cannot load `sqlalchemy-trino`. This image upgrades SQLAlchemy to **1.4.x** and installs `sqlalchemy-trino==0.5.0` and `trino==0.329.0` into Hue's own venv (`/usr/share/hue/build/env`). It is built for `linux/amd64` because the upstream base is amd64 only.

```bash
docker build --platform linux/amd64 -t hive-on-k8s/hue-trino:latest docker/hue-trino
kind load docker-image hive-on-k8s/hue-trino:latest --name desktop
```

## Hue → Trino and Cassandra

Hue has a `trino` interpreter (`sqlalchemy` interface, `trino://…/hive/default`). Cassandra is reached through Trino's `cassandra` catalog, not directly from Hue.

Verified: from the Hue pod, SQLAlchemy lists the `hive` schema (`default`) and the `cassandra` catalog's keyspaces (including `system_auth`). HiveServer2 (10000) and Trino (8080) are reachable over TCP from Hue.

Not yet verified: running a query end to end through Hue's UI for both Hive and Trino.

## Cassandra for Trino (two datacenters)

Trino's Cassandra connector supports only `PASSWORD` auth, so it can't read the Kerberos ring directly. The ring (`cassandra-0..2`, DC `warehouse`, RF=3) stays Kerberos-only. A single node `cassandra-trino` in a second DC, `trino` (RF=1), joins the same cluster with `PasswordAuthenticator` and mutual TLS; Trino reads and writes only that DC, and replication keeps the two DCs in sync. Design and provisioning steps: [cassandra-trino-two-dc-design.md](cassandra-trino-two-dc-design.md).

`hiveCtl.sh start warehouse` starts `cassandra-trino` after the ring and provisions its certificates, role, and replication when they're missing.

## Impala

Impala shares the Hive Metastore with Hive and Trino, so all three engines see the same tables and HDFS files. Trino has no Impala connector; Trino and Impala meet at the metastore, not through each other.

| Pod | Role | Kerberos principal |
|-----|------|--------------------|
| `impala-statestored-0` | Cluster membership | `impala/impala-statestored-0.impala-headless.warehouse.svc.cluster.local` |
| `impala-catalogd-0` | Reads the Hive Metastore (both HMS pods, SASL), polls HMS events, sends metadata to the impalads | `impala/impala-catalogd-0...` |
| `impalad-0..2` | Coordinator + executor | `impala/impalad-N...` |

Placement: each `impalad` must run on a node that has a `hadoop-datanode` pod, and no two `impalad`s share a node. The DataNodes stay on their nodes because their local-path PVs are node-bound, and in `warehouse` one DataNode per node is now required (it was only preferred). After a restore that moves the volumes, the `impalad`s follow.

Reads are remote. `impalad` and the DataNode have different pod IPs, so Impala does not count any block as local, and short-circuit reads are off (no shared socket). Traffic stays on the node when the scan lands next to the data. Real locality would need host networking on both the DataNodes and `impalad`.

HDFS access is as user `impala`, a `supergroup` member created by the NameNode setup script. Clients connect to Service `impala` (`21050` HS2 protocol, `21000` Beeswax, `25000` web UI) with Kerberos:

```bash
kubectl -n warehouse exec -it impalad-0 -- impala-shell -k -i impalad-0.impala-headless.warehouse.svc.cluster.local
```

Hue has an **Impala** editor (`[impala]` in `overlays/warehouse/hue/configmap.yaml`): the HS2 protocol on Service `impala:21050` with Hue's own Kerberos ticket, no impersonation (queries run as `hue`). Any impalad can coordinate:

- Every impalad keytab also holds `impala/impala.warehouse.svc.cluster.local`, exported once with `ktadd -norandkey` so all three share the key. impalad serves clients with it (`-principal`) and keeps `impala/<pod fqdn>` for daemon traffic (`-be_principal`). `start warehouse impala` adds it when missing.
- Service `impala` uses `sessionAffinity: ClientIP`: an HS2 session and its query handles live on one coordinator, and Hue may reconnect to fetch results. With one Hue pod this gives failover (a coordinator that fails readiness leaves the Service), not load spreading. Verified 2026-11-20: deleting the coordinator Hue was pinned to sent the next query to another impalad with no Hue change.

Hue stays at one pod by decision. More Hue pods would spread Impala traffic only loosely (affinity hashes client IPs, it does not round-robin), and the coordinators are not the bottleneck. Scale Hue for its own availability instead (two pods is enough). That needs `hue-1`/`hue-2` Kerberos principals in `warehouse-hosts.list`, the `hue-migrate` init container running on one pod only (it migrates the shared MySQL database and resets `admin` on every start), and `hiveCtl.sh` port-forward and NodePort helpers that don't assume `hue-0`. Sessions and query history are already in MySQL with one `hue-secret-key`, so users can move between pods.

### Query profiles

Each coordinator keeps the profiles of its last 100 queries in memory (`-query_log_size`) and serves them on its web UI (port `25000`); they are lost when the pod restarts. The query ID is in Hue's query output (`Query <id> 100% Complete`). Since the Service may have sent the query to any impalad, ask all three. The impalad image has no `curl`, so run it from `hue-0`; an impalad that doesn't know the query still answers 200 with a short error, hence the `grep`:

```bash
QID=d9495254cb968ed5:829f8d6b00000000
for i in 0 1 2; do
  kubectl -n warehouse exec hue-0 -c hue -- \
    curl -s "http://impalad-$i.impala-headless.warehouse.svc.cluster.local:25000/query_profile_plain_text?query_id=$QID" \
    > /tmp/profile-$QID.txt
  grep -q "Query (id=$QID)" /tmp/profile-$QID.txt && { echo "impalad-$i coordinated it: /tmp/profile-$QID.txt"; break; }
done
```

Other pages take the same `query_id`: `query_summary` (exec summary), `query_plan`, `query_profile_encoded`. To browse, `kubectl -n warehouse port-forward pod/impalad-0 25000:25000` and open `http://localhost:25000/queries`. In `impala-shell`, `profile;` right after a query prints it.

Hue's **Jobs → Queries** tab (Job Browser, `daemon_api_port=25000`) lists queries and profiles too, but it reaches the web UI through Service `impala`, and ClientIP affinity is per Service port, so it shows only the coordinator that port-25000 traffic is pinned to. Use the loop above when a query is missing there. The YARN/Spark tabs of the Job Browser are empty (no YARN in this profile).

On a cluster whose KDC predates Impala, `start warehouse impala` re-applies the KDC host list, creates the missing `impala/*` principals, and refreshes `kerberos-keytabs`.

## Ports and access

| Service | Port | Note |
|---------|------|------|
| Hue | `8889` (port-forward) · NodePort `30890` | Own range; does not conflict with `secure` (`8888` / `30889`) |
| HiveServer2 | Thrift `31040`, HTTP `31041`, Web UI `31042` (NodePorts) · forwards `11400` / `11401` / `11402` | Own range; `secure` uses `31030–31032` / `11300–11302` |

`secure` and `warehouse` can run at the same time on the port side. Both still compete for the same cluster CPU, memory, and disk; see the hardware notes in the README.

## Secrets

| Secret | Keys | Purpose |
|--------|------|---------|
| `kerberos-keytabs` | per-pod keytabs | Kerberos principals (synced from the KDC PVC by `hiveCtl`) |
| `cassandra-trino-role` | `username`, `password` | Trino's superuser role on the `trino` DC. Generated by `hiveCtl.sh` on first start. |
| `cassandra-trino-tls`, `trino-cassandra-tls`, `trino-cassandra-client-tls` | keystores, truststores, passwords, PEM client cert | mTLS between Trino and the `trino` DC, signed by an internal CA. Generated by `hiveCtl.sh` on first start. |

Keytab resync for this profile: `./hiveCtl.sh resync-keytabs warehouse` refreshes the Secret. Restart the Kerberos pods in `warehouse` afterward; only `secure` restarts automatically.

## Status

| Item | State |
|------|-------|
| Kerberos ring (3 Cassandra nodes), authenticated query | Verified |
| Trino (coordinator + 2 workers), Hive and Cassandra catalogs | Verified |
| Hue SQLAlchemy → Trino (`hive`, `cassandra` catalogs) | Verified |
| Hue → HiveServer2 TCP | Verified |
| Hue → Hive query through UI | Not yet verified |
| Hue → Trino query through UI | Not yet verified |
| Fresh cluster bring-up from zero | Not yet verified |
| Impala (catalogd ↔ Hive 4 metastore, queries on HDFS and Iceberg tables) | Verified (2026-11-20) |
| Hue → Impala editor | Verified via Hue's client (`INSERT`, `SELECT`, Iceberg `GROUP BY`) |
| Cloudera / EC2 deployment | Not started |
