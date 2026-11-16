# Warehouse profile

> Usage Notice: This project is not meant for commercial use without permission and proper credit.
> Author: j.martinez.poblete@gmail.com

The `warehouse` profile is a Kerberos-secured data warehouse in the `warehouse` namespace, realm `WAREHOUSE.LAB`. It builds on the [`secure`](secure-profile.md) Hive stack and adds **Cassandra** and **Trino**, both queryable from **Hue**.

> **Resource warning:** `warehouse` is memory heavy. It requests ~7 CPU and ~31 GiB RAM (limits ~67 GiB) and uses ~20.6 GiB at idle. Run it on a real cluster with 48 GiB+ of Kubernetes memory for meaningful testing; it does not fit a kind / Docker Desktop lab on a laptop. In our tests the `llap` profile runs fine on kind. Full sizing: [README hardware requirements](../README.md#hardware-requirements).

## Components

| Layer | Component | Image / source |
|-------|-----------|----------------|
| KDC | MIT Kerberos | `debian:bookworm-slim` (overlay `overlays/warehouse/krb5kdc`, host list `warehouse-hosts.list`) |
| HDFS | 1 NameNode + 3 DataNodes, `dfs.replication=3` | `apache/hadoop:3.4.1` |
| ZooKeeper | SASL/Kerberos | overlay `overlays/warehouse/zookeeper` |
| Cassandra (Kerberos ring) | 3 nodes, Kerberos-only auth | `hive-on-k8s/cassandra-kerberos:4.1.12` (custom, see below) |
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
| `jpoblete73/cassandra-kerberos:4.1.12` | Docker Hub (this repo's account) |
| `jpoblete73/ranger:2.4.0` | Docker Hub multi-arch tag: upstream `apache/ranger:2.4.0` (arm64, the only platform upstream publishes for 2.4.0) + `jpoblete73/ranger:2.4.0-amd64` built from `docker/ranger-admin` |
| `jpoblete73/oracle-free:23.9.0.0-amd64` | Docker Hub copy of Oracle's `container-registry.oracle.com/database/free:23.9.0.0-amd64` |

Oracle's original registry requires a login and license acceptance, which is why the copy is hosted here.
| Ranger | Admin (Hive policies) | overlay `overlays/warehouse/ranger` |
| Hive | Metastore + HiveServer2 (Kerberos), LLAP | `apache/hive:nightly` |
| Trino | 1 coordinator + 2 workers, Trino 484 | `trinodb/trino:484` |
| Hue | Hive + Trino interpreters | `hive-on-k8s/hue-trino` (custom, see below) |

## Startup and shutdown order

Startup: KDC → ZooKeeper / Hadoop (1 NN + 3 DN) → Cassandra ring → Cassandra `trino` DC → MySQL → PostgreSQL → Oracle → Ranger → Hive Metastore → LLAP → HiveServer2 → Trino → Hue.

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
| Cloudera / EC2 deployment | Not started |
