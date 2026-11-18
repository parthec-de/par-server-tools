# parbackup

Backup and restore of Docker deployments. parbackup dumps Postgres, MySQL and MongoDB databases inside their containers, copies Docker volumes and host directories, packs everything into one `.tar.gz` and uploads it to S3.

## Requirements

- **Bash**
- **Docker**
- **[gum](https://github.com/charmbracelet/gum):** log output and interactive prompts
- **[s3cmd](https://s3tools.org/s3cmd):** only for S3
- **[rsync](https://rsync.samba.org/):** only for restoring `dir` services

parbackup installs missing tools via `apt` on Debian and Ubuntu only.

## Configuration

```bash
parbackup config set   # configure interactively
parbackup config       # show the current configuration
```

The settings live in `~/.config/par/parbackup.conf`:

| Key              | Purpose                                      |
| ---------------- | -------------------------------------------- |
| `S3_ENDPOINT`    | S3 endpoint                                  |
| `S3_BUCKET`      | Bucket for all backups                       |
| `S3_ACCESS_KEY`  | Access key                                   |
| `S3_SECRET_KEY`  | Secret key                                   |
| `S3_REGION`      | Signing region, see below                    |
| `RETENTION_DAYS` | Days to keep backups, `0` keeps them forever |

Leave `S3_REGION` empty for providers that ignore it, e.g. Hetzner. Providers that validate it need a value, e.g. `us-east-1` for AWS or RustFS.

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

| Variable          | Purpose                                                      |
| ----------------- | ------------------------------------------------------------ |
| `BACKUP_NAME`     | Name of the backup, used for archive names and the S3 prefix |
| `SERVICES`        | Comma-separated service names                                |
| `RETENTION_DAYS`  | Optional, overrides the configured retention for this backup |
| `<SVC>_TYPE`      | `postgres`, `mysql`, `mongo`, `volume` or `dir`              |
| `<SVC>_CONTAINER` | Container name, for all types except `dir`                   |
| `<SVC>_USER`      | Database user                                                |
| `<SVC>_PASSWORD`  | Database password                                            |
| `<SVC>_DB`        | Database name                                                |
| `<SVC>_PATH`      | Path inside the container (`volume`) or on the host (`dir`)  |

`<SVC>` is the service name from `SERVICES` in upper case.

### Service types

| Type       | Backup                                                | Restore                               |
| ---------- | ----------------------------------------------------- | ------------------------------------- |
| `postgres` | `pg_dump` inside the container                        | `pg_restore`                          |
| `mysql`    | `mysqldump --single-transaction` inside the container | Drops and recreates the database      |
| `mongo`    | `mongodump` inside the container                      | `mongorestore`                        |
| `volume`   | `docker cp` tar stream, stored as `volume.tar`        | Clears the path, keeps owner and mode |
| `dir`      | `cp -a` on the host                                   | `rsync --delete`                      |

Archives from before v1.7.0 have no `volume.tar`. Their volume files come back owned by root.

### Several Parbackupfiles per deployment

Data with a different schedule or retention goes into its own Parbackupfile with its own `BACKUP_NAME`, e.g. `Parbackupfile.assets` for files that can be regenerated:

```bash
BACKUP_NAME="my_project_assets"
RETENTION_DAYS="28"
```

`RETENTION_DAYS="0"` keeps a backup forever, e.g. for a one-off backup before a migration.

## Usage

### Create a backup

```bash
parbackup create -f /opt/my-project/Parbackupfile
```

| Option         | Effect                                               |
| -------------- | ---------------------------------------------------- |
| `-f <path>`    | Parbackupfile to use, default `./Parbackupfile`      |
| `--local`      | No S3 upload, the archive stays in `/tmp/parbackup/` |
| `--keep-local` | Keeps the local archive after the S3 upload          |

- **Archive:** `<BACKUP_NAME>-<timestamp>.tar.gz` with one directory per service, the Parbackupfile and a `parbackup.log`
- **Parbackupfile in the archive:** always named `Parbackupfile`, restore reads the services from it
- **S3:** the archive lands under the prefix `<BACKUP_NAME>/`
- **Local copy:** removed after a successful upload

### Restore

```bash
parbackup restore --pick                                          # pick from S3
parbackup restore my_project/my_project-2026-02-27_14-30-22.tar.gz
parbackup restore --local /tmp/parbackup/my_project-2026-02-27_14-30-22.tar.gz
```

Restore asks for confirmation, `--force` skips it. `--local` accepts a `.tar.gz` or an unpacked directory.

### Download, list

```bash
parbackup download --pick                  # to /tmp/parbackup/, --force overwrites
parbackup ls                               # all backups
parbackup ls my_project/                   # one prefix
parbackup ls --tree                        # as a tree
parbackup ls --timestamps                  # <epoch>\t<key> per line
```

### Retention

After each successful `create`, parbackup deletes the backups of the same `BACKUP_NAME` that are older than the retention. The `RETENTION_DAYS` of the Parbackupfile takes precedence over the configuration.

```bash
parbackup cleanup -f /opt/my-project/Parbackupfile   # one Parbackupfile, its retention
parbackup cleanup                                    # whole bucket, configured retention
parbackup cleanup --dry-run                          # only show what would be deleted
```

Without `-f`, the cleanup ignores the `RETENTION_DAYS` of Parbackupfiles and also deletes backups meant to be kept longer.

### Cron

```bash
parbackup cron -f /opt/my-project/Parbackupfile --schedule "0 3 * * *"
parbackup cron show
parbackup cron remove -f /opt/my-project/Parbackupfile
```

Without `--schedule`, parbackup asks for the frequency. Each entry carries the marker `# parbackup:<BACKUP_NAME>`, so each `BACKUP_NAME` has at most one entry.

### Update

```bash
parbackup updateself
```

## Logs and alerts

- **Backup log:** `parbackup.log` in the archive, with every step up to packaging
- **Run log:** `/tmp/parbackup/runs/run-*.log` covers the whole run including the upload, removed on success and kept on failure
- **Alerts:** on failure, parbackup sends exit code, line and run log via [paralert](../paralert/)

Without paralert or its configuration, the failure only shows up in the output.

## Development

The tests run against Postgres, MySQL, MongoDB, a volume container, RustFS as S3 and MailPit from `./test/`:

```bash
mise run test:parbackup
```

Run the test stack manually:

```bash
cd test/
docker compose up -d
../parbackup create --local
../parbackup restore --local --force /tmp/parbackup/test_deployment-<timestamp>.tar.gz
docker compose down -v
```
