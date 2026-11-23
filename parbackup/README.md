# parbackup

parbackup backs up and restores Docker deployments:

- **Databases:** `pg_dump`, `mysqldump` and `mongodump`, run inside their containers
- **Files:** Docker volumes and host directories

The result is processed by one of two backends, see [Backends](#backends).

## Requirements

- **Bash**
- **Docker**
- **[gum](https://github.com/charmbracelet/gum):** log output and interactive prompts
- **[s3cmd](https://s3tools.org/s3cmd):** only for S3
- **[restic](https://restic.net/):** only for the restic backend
- **[rsync](https://rsync.samba.org/):** only for restoring `dir` services

parbackup installs missing tools via `apt` on Debian and Ubuntu only. restic 0.16 or newer is required. It compresses by default and prunes faster than older releases. A pinned version from `mise` or NixOS is preferable to the distribution package.

## Backends

| Backend             | Storage                             | Retention              | Space per run     |
| ------------------- | ----------------------------------- | ---------------------- | ----------------- |
| `builtin` (default) | `<BACKUP_NAME>/` in the bucket      | age in days            | the whole archive |
| `restic`            | `<prefix>/<BACKUP_NAME>` repository | daily, weekly, monthly | changed chunks    |

`BACKUP_BACKEND` selects the default. A Parbackupfile can override it.

The restic backend reads volumes and host directories at their host paths, so unchanged media and thumbnails are neither copied nor uploaded again. It also encrypts the repository, which keeps database passwords from the Parbackupfile and `.env` files out of plaintext object storage.

## Configuration

```bash
parbackup config set           # S3 and the backend
parbackup config set s3        # S3 only
parbackup config set restic    # backend, repo-prefix, secret, retention
parbackup config               # show the current configuration
```

The settings live in `~/.config/par/parbackup.conf`:

| Key                  | Default                       | Purpose                                          |
| -------------------- | ----------------------------- | ------------------------------------------------ |
| `BACKUP_BACKEND`     | `builtin`                     | `builtin` or `restic`                            |
| `S3_ENDPOINT`        |                               | S3 endpoint                                      |
| `S3_BUCKET`          |                               | Bucket for all backups                           |
| `S3_ACCESS_KEY`      |                               | Access key                                       |
| `S3_SECRET_KEY`      |                               | Secret key                                       |
| `S3_REGION`          |                               | Signing region, see below                        |
| `RESTIC_REPO_PREFIX` | `restic`                      | Prefix in the bucket                             |
| `RESTIC_SECRET_FILE` | `~/.config/par/restic-secret` | File with the repository password, mode 600      |
| `RESTIC_CACHE_DIR`   | `/var/cache/parbackup/restic` | restic cache, keep it across reboots             |
| `RETENTION_DAYS`     | `7`                           | Age in days (builtin) or `--keep-daily` (restic) |
| `RETENTION_WEEKLY`   | unset                         | `--keep-weekly`, restic only                     |
| `RETENTION_MONTHLY`  | unset                         | `--keep-monthly`, restic only                    |

Leave `S3_REGION` empty for providers that ignore it, e.g. Hetzner. Providers that validate it need a value, e.g. `us-east-1` for AWS or RustFS.

The restic repository is always built from `S3_ENDPOINT`, `S3_BUCKET` and `RESTIC_REPO_PREFIX`, so the S3 settings stay the single source of truth for the target: `s3:<endpoint>/<bucket>/<prefix>/<BACKUP_NAME>`. An empty `RESTIC_REPO_PREFIX` puts the repositories directly below the bucket.

The restic repository is encrypted with the password from `RESTIC_SECRET_FILE`, a `RESTIC_PASSWORD` environment variable takes precedence. Losing that password means losing every snapshot, so keep a copy outside the host. parbackup refuses a secret file that is readable by group or others.

## Parbackupfile

A `Parbackupfile` in the deployment directory describes what to back up:

```bash
BACKUP_NAME="my_project"

SERVICES="app_db,app_uploads,app_static"

APP_DB_TYPE="postgres"
APP_DB_CONTAINER="my-project-postgres-1"
APP_DB_USER="postgres"
APP_DB_PASSWORD="secret"
APP_DB_DB="mydb"

APP_UPLOADS_TYPE="volume"
APP_UPLOADS_CONTAINER="my-project-app-1"
APP_UPLOADS_PATH="/app/public/uploads"

APP_STATIC_TYPE="dir"
APP_STATIC_PATH="/opt/my-project/static"
```

| Variable            | Purpose                                                      |
| ------------------- | ------------------------------------------------------------ |
| `BACKUP_NAME`       | Name of the backup, used for repository and archive names    |
| `BACKUP_BACKEND`    | Optional, `builtin` or `restic`, overrides the configuration |
| `SERVICES`          | Comma-separated service names                                |
| `RETENTION_DAYS`    | Optional, overrides the configured retention for this backup |
| `RETENTION_WEEKLY`  | Optional, `--keep-weekly`, restic only                       |
| `RETENTION_MONTHLY` | Optional, `--keep-monthly`, restic only                      |
| `<SVC>_TYPE`        | `postgres`, `mysql`, `mongo`, `volume` or `dir`              |
| `<SVC>_CONTAINER`   | Container name, for all types except `dir`                   |
| `<SVC>_USER`        | Database user                                                |
| `<SVC>_PASSWORD`    | Database password                                            |
| `<SVC>_DB`          | Database name                                                |
| `<SVC>_PATH`        | Path inside the container (`volume`) or on the host (`dir`)  |

`<SVC>` is the service name from `SERVICES` in upper case.

### Service types

| Type       | Backup (builtin)                                      | Restore (builtin)                     | Backup (restic)                  |
| ---------- | ----------------------------------------------------- | ------------------------------------- | -------------------------------- |
| `postgres` | `pg_dump` inside the container                        | Drops and recreates the database      | dump in the snapshot             |
| `mysql`    | `mysqldump --single-transaction` inside the container | Drops and recreates the database      | dump in the snapshot             |
| `mongo`    | `mongodump` inside the container                      | `mongorestore`                        | dump in the snapshot             |
| `volume`   | `docker cp` tar stream, stored as `volume.tar`        | Clears the path, keeps owner and mode | reads the host path of the mount |
| `dir`      | `cp -a` on the host                                   | `rsync --delete`                      | reads the host path directly     |

For a `volume` service the restic backend resolves the host directory of the mount through `docker inspect`, for named volumes and bind mounts alike. A container path that is no mount (content from the image) falls back to the `docker cp` tar stream.

Archives from before v1.7.0 have no `volume.tar`. Their volume files come back owned by root.

### Several Parbackupfiles per deployment

Data with a different schedule or retention goes into its own Parbackupfile with its own `BACKUP_NAME`, e.g. `Parbackupfile.assets` for files that can be regenerated:

```bash
BACKUP_NAME="my_project_assets"
RETENTION_DAYS="7"
RETENTION_WEEKLY="4"
```

Each `BACKUP_NAME` gets its own restic repository, so retention and prune stay scoped to that data. `RETENTION_DAYS="0"` keeps a backup forever, e.g. for a one-off backup before a migration.

## Usage

### Create a backup

```bash
parbackup create -f /opt/my-project/Parbackupfile
```

| Option         | Effect                                                     |
| -------------- | ---------------------------------------------------------- |
| `-f <path>`    | Parbackupfile to use, default `./Parbackupfile`            |
| `--local`      | No upload, the staging tree stays in place for inspection  |
| `--keep-local` | Keeps the staging tree after a successful upload           |
| `--no-prune`   | restic: forgets snapshots beyond retention without pruning |

- **Staging:** `<BACKUP_NAME>` with one directory per service, the Parbackupfile and a `parbackup.log`
- **Parbackupfile in the backup:** always named `Parbackupfile`, restore reads the services from it
- **Staging path:** `/var/cache/parbackup/staging/<BACKUP_NAME>`, override with `PARBACKUP_STAGING_ROOT`
- **After success:** the contents of the staging tree are removed, the tree itself stays

The backend decides what happens with the staging tree:

- **builtin:** packs it into `<BACKUP_NAME>-<timestamp>.tar.gz`, uploads it under `<BACKUP_NAME>/` and removes the local archive
- **restic:** stores it, together with the host paths of volumes and directories, as one snapshot tagged with `BACKUP_NAME`, and creates the repository on the first run

### Restore

```bash
parbackup restore --pick                                          # pick from the backend
parbackup restore my_project/my_project-2026-02-27_14-30-22.tar.gz # builtin archive
parbackup restore my_project/1a2b3c4d                              # restic snapshot
parbackup restore --local /tmp/parbackup/my_project-2026-02-27_14-30-22.tar.gz
```

Restore asks for confirmation. `--force` skips it. `--local` accepts a `.tar.gz`, an unpacked builtin backup or an unpacked restic restore tree.

Volumes are restored through `docker cp` from the snapshot data, directories through `rsync --delete`. A restore as root keeps owner and mode. A restore as a regular user cannot set uid and gid.

### Download, list

```bash
parbackup download --pick                  # to /tmp/parbackup/
parbackup ls                               # all backups
parbackup ls my_project/                   # one deployment
parbackup ls --timestamps                  # <epoch>\t<key> per line
```

Builtin backups download to a `.tar.gz`, restic snapshots restore into a directory. `ls` prints one reference per line, `<BACKUP_NAME>/<archive>` for builtin and `<BACKUP_NAME>/<short_id>` for restic. `--tree` applies to the builtin backend.

A bucket can hold both kinds during a migration. The reference decides what `download` and `restore` do, the configured backend only decides what `create` writes.

### Retention

After each successful `create`, parbackup removes backups beyond the retention of that `BACKUP_NAME`. The `RETENTION_DAYS` of the Parbackupfile takes precedence over the configuration.

```bash
parbackup cleanup -f /opt/my-project/Parbackupfile   # one Parbackupfile, its retention
parbackup cleanup                                    # all backups, configured retention
parbackup cleanup --dry-run                          # only show what would be deleted
parbackup cleanup --backend builtin                  # old archives after a switch to restic
```

The builtin backend deletes archives older than the retention in days. The restic backend maps the settings to `restic forget --keep-daily/--keep-weekly/--keep-monthly` and prunes in the same run, so the freed space disappears from the bucket.

`RETENTION_WEEKLY` and `RETENTION_MONTHLY` apply to restic only. The builtin backend warns when a Parbackupfile sets them.

Without `-f`, the cleanup ignores the `RETENTION_DAYS` of Parbackupfiles and also deletes backups meant to be kept longer.

### Restic maintenance

```bash
parbackup restic init -f /opt/my-project/Parbackupfile     # create the repository
parbackup restic prune -f /opt/my-project/Parbackupfile    # release the space of forgotten snapshots
parbackup restic prune --dry-run                           # show what prune would free
parbackup restic check -f /opt/my-project/Parbackupfile    # verify the repository
parbackup restic check --read-data-subset 1/7              # read a share of the packs
```

`restic init` creates the repository of that Parbackupfile, `create` does the same on its first run. A Parbackupfile with `BACKUP_BACKEND="builtin"` is refused, there is no repository to create for it.

`create` prunes by itself. `--no-prune` skips that and leaves the space to a later `restic prune`. Run the check weekly, so damaged packs show up before a restore needs them.

`restic prune` and `restic check` work on the repository of one Parbackupfile with `-f`, or on every repository under `RESTIC_REPO_PREFIX` without it. A repository stays reachable after its Parbackupfile switches to `builtin`. A file without a repository is reported and skipped.

### Cron

```bash
parbackup cron -f /opt/my-project/Parbackupfile --schedule "0 3 * * *"
parbackup cron show
parbackup cron remove -f /opt/my-project/Parbackupfile
```

Without `--schedule`, parbackup asks for the frequency. Each entry carries the marker `# parbackup:<BACKUP_NAME>`, so each `BACKUP_NAME` has at most one entry.

## Logs and alerts

- **Backup log:** `parbackup.log` in the staging tree, with every step up to packaging, part of the builtin archive and of the restic snapshot
- **Run log:** `/tmp/parbackup/runs/run-*.log` covers the whole run including the upload, removed on success and kept on failure
- **Alerts:** on failure, parbackup sends exit code, line and run log via [paralert](../paralert/)

Without paralert or its configuration, the failure only shows up in the output.

## Migration from builtin to restic

1. Set `BACKUP_BACKEND="restic"`, choose a secret file and store the password outside the host
2. Create the repository and one snapshot:

   ```bash
   parbackup restic init -f <Parbackupfile>
   parbackup create -f <Parbackupfile>
   ```

3. Restore that snapshot on a scratch host and check databases, volumes and ownership
4. Switch the cron entry
5. Let the old archives expire:

   ```bash
   parbackup cleanup --backend builtin -f <Parbackupfile>
   ```

No S3 lifecycle rule may expire objects under `<prefix>/`. It would corrupt the repository. Bucket versioning also keeps pruned data alive and costs storage, so the repository belongs in a bucket without lifecycle rules.

## Development

The tests run against Postgres, MySQL, MongoDB, a volume container, a bind mount, RustFS as S3 and MailPit from `./test/`:

```bash
mise install
mise run test:parbackup
```

The restic tests need `restic` on the `PATH`, which `mise` provides. They keep staging and cache in temporary directories. The tests do not run as root.

Run the test stack manually:

```bash
cd test/
docker compose up -d
../parbackup create --local
../parbackup restore --local --force /tmp/parbackup/test_deployment-<timestamp>.tar.gz
docker compose down -v
```
