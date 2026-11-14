# Trino database catalogs (MySQL, PostgreSQL, Oracle)

Usage Notice: This project is not meant for commercial use without permission and proper credit.
Author: j.martinez.poblete@gmail.com

Trino reads three relational databases in the warehouse namespace, all through a `bigdata` database or schema. This page covers where each lives, how to query it, and how it's set up.

## Naming convention

`<engine>.bigdata` is the data location, and the Trino catalog name matches the engine:

| Engine | Version | Trino catalog | Where `bigdata` lives | Query path |
| --- | --- | --- | --- | --- |
| MySQL | 8.4 (`mysql:8.4`) | `mysql` | database `bigdata` | `mysql.bigdata.<table>` |
| PostgreSQL | 16 (`postgres:16`) | `postgres` | database `bigdata`, schema `bigdata` | `postgres.bigdata.<table>` |
| Oracle | 23ai Free (`23.9.0.0-amd64`) | `oracle` | user/schema `bigdata` | `oracle.bigdata.<table>` |

Redis is out of scope for now. Redis has no named databases, so it would use a key-prefix or numbered-DB convention and isn't exposed through Trino.

### Oracle case sensitivity

Oracle stores unquoted identifiers in uppercase, but the `bigdata` user and `sample_customers` table here are created in lowercase, as written. Trino's Oracle connector looks names up in uppercase by default, so it can't see them without `case-insensitive-name-matching=true` in `overlays/warehouse/trino/oracle.properties`. With that set, the query is `oracle.bigdata.sample_customers`, with no quoting.

Without the setting, Trino lists neither the table nor the schema, while Hue still shows the schema from a different metadata path. If the Oracle catalog ever shows an empty table list, check this setting first.

## Where things live

| Piece | Location |
| --- | --- |
| Trino catalog files | `overlays/warehouse/trino/mysql.properties`, `postgres.properties`, `oracle.properties` |
| Trino wiring (copy, password append, Secret mount) | `overlays/warehouse/trino/statefulset.yaml` (coordinator and worker) |
| Trino catalog ConfigMap entries | `overlays/warehouse/trino/kustomization.yaml` (`trino-catalogs`) |
| MySQL component | `overlays/warehouse/mysql` (base `components/mysql`) |
| MySQL setup | `components/mysql/setup/bigdata-schema.sql`, `apply-bigdata-schema.sh` |
| Postgres component | `components/postgres`, overlay `overlays/warehouse/postgres` |
| Postgres setup | `components/postgres/setup/bigdata-schema.sql`, `apply-bigdata-schema.sh` |
| Oracle component | `components/oracle`, overlay `overlays/warehouse/oracle` |
| Oracle setup | `components/oracle/setup/bigdata-schema.sql`, `apply-bigdata-schema.sh` |

## Passwords

No password is stored in the repo. Each one lives in the `hive-credentials` Secret in namespace `warehouse`:

| Key | Used by |
| --- | --- |
| `mysql-trino-password` | Trino `mysql` catalog (user `trino`) |
| `postgres-trino-password` | Trino `postgres` catalog (role `trino`) |
| `oracle-trino-password` | Trino `oracle` catalog (user `trino`) |
| `postgres-password`, `oracle-password` | Database admin accounts (`postgres` superuser, Oracle `SYS`/`SYSTEM`/`PDBADMIN`) |

Trino reads each catalog password from a Secret volume at startup and appends it to the catalog file, the same way the Cassandra password is handled.

## Setup order (fresh cluster)

1. Create the `hive-credentials` keys above (the Postgres and Oracle setup scripts create the trino password keys if missing).
2. MySQL: `bash components/mysql/setup/apply-bigdata-schema.sh`. Idempotent; creates the `bigdata` database, sample table, and `trino` grants.
3. Postgres: `kubectl apply -k overlays/warehouse/postgres`, then `bash components/postgres/setup/apply-bigdata-schema.sh`. Idempotent.
4. Oracle: create the `oracle-registry` pull secret (see below), then `kubectl apply -k overlays/warehouse/oracle`, wait for the database to report `DATABASE IS READY TO USE`, then `bash components/oracle/setup/apply-bigdata-schema.sh`. Idempotent.
5. Trino: `kubectl apply -k overlays/warehouse/trino`, then restart the coordinator and workers so the catalogs load.

## Oracle image

The StatefulSet uses `jpoblete73/oracle-free:23.9.0.0-amd64`, a copy of Oracle's `container-registry.oracle.com/database/free:23.9.0.0-amd64` hosted on Docker Hub. The copy means a new cluster pulls without an Oracle login.

Only if you want to pull from Oracle's registry instead (for example to refresh the copy), the source needs an authenticated pull. Create the secret with an Oracle **auth token**, not the account password:

```bash
kubectl -n warehouse create secret docker-registry oracle-registry \
  --docker-server=container-registry.oracle.com \
  --docker-username=<oracle-sso-email> \
  --docker-password=<auth-token>
```

The account must have accepted the Database Free license. Do not commit the token.

## Verifying

```bash
# Catalogs loaded
kubectl -n warehouse exec trino-coordinator-0 -- sh -c 'ls /usr/lib/trino/etc/catalog/'

# Each catalog answers a query (sample table: 3 rows)
kubectl -n warehouse exec trino-coordinator-0 -- sh -c 'trino --user admin --execute "SELECT * FROM mysql.bigdata.sample_customers"'
kubectl -n warehouse exec trino-coordinator-0 -- sh -c 'trino --user admin --execute "SELECT * FROM postgres.bigdata.sample_customers"'
kubectl -n warehouse exec trino-coordinator-0 -- sh -c 'trino --user admin --execute "SELECT * FROM oracle.bigdata.sample_customers"'
```

## Known issues and gotchas

- **MySQL connector URL must not include a database.** The database is chosen by the catalog's schema. Including `/bigdata` in `connection-url` crashes the coordinator with `Database (catalog) must not be specified in JDBC URL`.
- **PostgreSQL connector URL must include the database** (`/bigdata`). The opposite of MySQL.
- **Oracle needs `case-insensitive-name-matching=true`** for the lowercase `bigdata` layout. Without it, the table list is empty (see Oracle case sensitivity above).
- **Oracle table list empty after a restart.** Check, in order: (1) `SHOW TABLES FROM oracle.bigdata` in Trino, (2) that `case-insensitive-name-matching=true` is still in the rendered catalog, (3) that the table exists in Oracle with `SELECT owner||'.'||table_name FROM dba_tables WHERE table_name='sample_customers'`. The database-side grants and logins were correct throughout; the missing piece was the case setting.
- **Oracle `GRANT` must follow table creation.** A grant on a missing object fails, which left `trino` with no access on a fresh run. The setup script now creates the table first.
- **Oracle first start is slow.** The pod reports Ready once the listener is up, but the database can still be creating (`Copying database files`). Wait for `DATABASE IS READY TO USE` in `kubectl logs oracle-0` before running setup.
- **Oracle password rules.** The `ORACLE_PWD` value must be at least 8 characters with an uppercase letter, a lowercase letter, and a digit.
- **Trino lists only schemas the user can see.** Oracle users with no privileges on any object don't appear in `SHOW SCHEMAS`, but they can still be queried by name.
- **Oracle has no `ROWS` alias.** `ROWS` is reserved; use another alias in `COUNT(*) AS n`.

## Open items

- Redis: not exposed through Trino; naming to be defined when added.
- Trino UI has no authentication (see `docs/trino-iceberg-runbook.md`).