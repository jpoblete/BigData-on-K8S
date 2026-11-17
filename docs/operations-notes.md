# Operations notes: backup, restore, cleanup, and the live cluster

> Usage Notice: This project is not meant for commercial use without permission and proper credit.
> Author: j.martinez.poblete@gmail.com

Notes from the November 2026 work on full-namespace backup/restore and the first end-to-end `cleanup` → `restore` test on the live `warehouse` cluster. Open items are at the end.

## Live cluster

| Item | Value |
|---|---|
| Access | `ssh jpoblete@34.234.33.208` (bastion with `kubectl` access) |
| Nodes | 1 control-plane + 5 workers (label `node-role.kubernetes.io/llap`), Kubernetes v1.34, AWS `us-east-1a` |
| StorageClasses | `block-storage` (EBS, default), `hive-on-k8s-local-path` (local-path, `Retain`) |
| Checkout | `~/BigData-on-K8S`, remote `https://github.com/jpoblete/BigData-on-K8S.git` |

Rule: **the live cluster's checkout always matches `origin/main`.** Make changes in the repo, push, then `git pull --ff-only` on the bastion. Do not edit files on the bastion.

The checkout was previously at `~/Hive-on-K8S`, 61 commits behind, with uncommitted edits. It was renamed and reset to `main`; the old local edits are preserved on the bastion-only branch `local-backup-20261115-1642`.

## Backup format (all profiles)

`./hiveCtl.sh backup <profile>` saves the whole namespace to `./backups/<profile>-YYYYMMDD-HHMMSS/`:

| File | Contents |
|---|---|
| `secrets.json` | Every Secret except service-account tokens and Helm releases |
| `pvc/<pvc>.tgz` | Files of every bound PVC (`tar --numeric-owner`) |
| `pvcs.txt` | PVC name, StorageClass, size, access mode, node/zone of its PV |
| `workloads.txt` | `kind/name replicas` for every StatefulSet/Deployment |
| `overlays.txt` | Active overlays (informational) |
| `manifests.json` | StatefulSets, Deployments, Services, ConfigMaps, ServiceAccounts, Roles, RoleBindings as they were running |

How it works:

1. Export Secrets, manifests, replica counts, and the PVC inventory.
2. Scale every workload to zero and wait until no pod mounts a PVC (consistent copy of MySQL, Postgres, Oracle, Cassandra, the KDC, HDFS).
3. For each PVC, start a root helper pod (`busybox:1.36`, override `HIVECTL_PVC_HELPER_IMAGE`) and stream a `tar` of the volume to the bastion.
4. Scale workloads back to their recorded replica counts.

Expect a short outage. The `warehouse` backup took about 10 minutes and 1.6 GB (HDFS DataNodes ~1.5 GB, Oracle ~730 MB compressed). Backup directories hold credentials and data: treat them as sensitive (`chmod 700` is applied).

## Restore

`./hiveCtl.sh restore <profile> <backup-dir>` works on a running namespace, after `cleanup`, or on a new cluster:

1. Scale any existing workloads to zero.
2. Apply `secrets.json` (existing Secrets are overwritten with the backup's).
3. Re-create missing PVCs with the saved class/size, preferring the original node or zone (local-path volumes are node-bound; keeping the original placement keeps DataNodes on separate nodes), then replace each volume's contents.
4. `kubectl apply` `manifests.json`, so the exact running specs come back, including image overrides given at start time (for example `RANGER_ADMIN_IMAGE`) and objects applied outside an overlay.
5. Scale workloads that were not in the backup to zero, then scale every backed-up workload to its recorded count and wait for rollouts.

Restore does **not** re-run `start`: databases, users, roles, keytabs, and schemas all come back from the volumes, so no setup script needs re-running.

Backups in the older formats (`mysql-hive.sql` + `hdfs-backup.tgz`, or `standalone-hive.tgz`) still restore with the previous logic.

## Cleanup

`./hiveCtl.sh cleanup <profile>` offers a backup, asks for the profile name, runs `stopStack`, then scales down any workload `stopStack` doesn't list (optional or hand-applied components would otherwise keep their PVCs from being deleted), deletes all PVCs, their PVs, and the namespace.

On non-Kind clusters (no `docker`), cleanup runs one short-lived pod per node in `local-path-storage` that removes `pvc-*_<namespace>_*` under the provisioner base path, so node disks are left clean.

## Test run: `warehouse` cleanup → restore (2026-11-15)

Baseline and post-restore checks matched:

| Check | Result |
|---|---|
| 16 StatefulSets, same replica counts | Identical, all Ready |
| Trino `mysql` / `postgres` / `oracle` `bigdata.sample_customers` | 3 / 3 / 3 rows |
| Trino `iceberg.default.iceberg_orc_3_1` | 10,400 rows |
| Trino `cassandra.demo.dummy_3` | 10 rows |
| Hive metastore | 3 databases, 76 tables |
| MySQL databases and users, Hue users, KDC principals (64) | Identical |
| HDFS | Matches the backup; extra files vs. the morning baseline were service logs, scratch dirs, and the HS2 jar cache written by restarts before the backup |

Problems found and fixed during the run:

| Problem | Fix |
|---|---|
| Old backup didn't cover `warehouse`: wrong HDFS pod (`hadoop-0`), no Kerberos, and no MySQL `bigdata`/`ranger`/`hue`, Postgres, Oracle, Cassandra, KDC, or most Secrets | Full-namespace backup (above) |
| Old standalone backup missed the Hue MySQL volume | Same |
| `trino-worker` StatefulSet had no `app: trino` label, so `stop`/`cleanup` timed out while its pods kept coming back | Label added |
| `stopStack warehouse` doesn't stop `cassandra-trino`, `oracle`, `postgres`, `llapdaemon`; their PVCs stuck in `Terminating` | Cleanup scales down every remaining workload |
| First restore re-ran `start` from the repo: Ranger came up on `apache/ranger:2.4.0` (wrong architecture, `exec format error`) instead of `jpoblete73/ranger:2.4.0-amd64`, and `cassandra-pw` was started | Restore applies the backed-up manifests instead |
| Backup stripped `clusterIP: None`, so headless Services came back as normal ClusterIP Services (per-pod DNS such as `hiveserver2-0.hiveserver2-headless` broke) | Backup keeps `clusterIP: None`; the five affected Services were re-created headless |
| `main` started `cassandra-pw`, whose image `hive-on-k8s/cassandra-password:4.1.12` is in no registry | `cassandra-pw` retired; `cassandra-trino` (overlay `overlays/warehouse/cassandra-trino`) starts in its place; Trino reads `cassandra-trino-role` |

## Second test run: clean slate → restore (2026-11-16)

Cleanup with backup (`backups/warehouse-20261116-164212`, the only backup kept on the bastion), then `warehouse` and `secure` namespaces, their PVs, and node directories were removed. Restore brought back all 16 StatefulSets with the same row counts, Hive metastore, KDC principals, and Hue users as the baseline. Cassandra, Oracle, and Postgres PVCs came back on `block-storage`.

Resolved since the first run:

| Item | Resolution |
|---|---|
| `start`/`stop warehouse` skipped `llapdaemon`, `postgres`, `oracle` | Both now include them; `start` applies the Postgres/Oracle `apply-bigdata-schema.sh` |
| `cassandra-trino` provisioning was manual | `start` generates TLS Secrets and `cassandra-trino-role`, creates the role, and adds `trino:1` replication (with `nodetool rebuild`) |
| Ranger default image didn't run on amd64 | `jpoblete73/ranger:2.4.0` is multi-arch (arm64 from `apache/ranger:2.4.0`, amd64 from `jpoblete73/ranger:2.4.0-amd64`); keep the `-amd64` tag, it backs the manifest list |
| `deployments.apps "trino" not found` | `waitForReady` falls back to workloads labelled `app=<service>` |
| Released `secure` PVs | Deleted with their node directories |
| Cassandra init failed with `exec format error` on one node | A stale wrong-arch `cassandra-kerberos:4.1.12` was cached there; both Cassandra overlays use `imagePullPolicy: Always` |

## Third test run: fresh `warehouse` start (2026-11-17)

Cleanup with backup (`backups/warehouse-20261117-170931`), then `./hiveCtl.sh start warehouse` on an empty namespace. The backup was not restored. All 16 StatefulSets came up Ready.

| Check | Result |
|---|---|
| Trino `mysql` / `postgres` / `oracle` `bigdata.sample_customers` | 3 / 3 / 3 rows |
| Trino `cassandra` | Connects; system schemas only (no `demo` keyspace on a new volume) |
| Hive metastore | 3 databases (`default`, `information_schema`, `sys`), 75 tables |
| Hue | Login page HTTP 200; `hue-admin` password is set in `hive-credentials` |

Problems found and fixed during the run:

| Problem | Fix |
|---|---|
| `cassandra-trino` password login failed with `LOCAL_QUORUM` on `system_auth` (no replica in the `trino` DC yet), and the Kerberos ring rejects `CREATE ROLE ... PASSWORD` | Replication is altered over GSSAPI on `cassandra-0`, data is rebuilt onto `cassandra-trino`, then the role is created there |
| A retry then failed with `not allowed to alter your own superuser status` | `CREATE ROLE` sets superuser; later runs only refresh `LOGIN` and the password |
| Oracle schema apply ran while `FREEPDB1` did not exist yet, and `sqlplus` still exited 0 | Wait until `FREEPDB1` is `READ WRITE`, and fail the script on SQL errors |
| Hive SYS schema init never ran: `ensureHiveSysSchema` handles `warehouse`, but `hs2OverlayServiceStarted` did not call it | `warehouse` is included with the other HiveServer2 profiles |

## Open items

- **Hue login** now comes from `hive-credentials.hue-admin-password` (`./hiveCtl.sh get passwd <profile> hue-admin`); the `hue-migrate` init container creates or updates Django user `admin` to match on every start. A password changed in the Hue UI is reset on the next restart; change it in the Secret and restart Hue instead (see the README, "Hue `admin` password"). Hive and Trino queries from the Hue editor were verified after the 2026-11-16 restore (Hive `iceberg_orc_3_1` = 10,400 rows; Trino `mysql.bigdata.sample_customers` = 3 rows).
