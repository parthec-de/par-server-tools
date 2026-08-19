# parbackup

Backup tool for Docker-based deployments. Creates online dumps of Postgres and MongoDB databases running in Docker containers, backs up Docker volumes and local directories, packages them as `.tar.gz`, and uploads to S3.

## Requirements

- Bash
- Docker
- [gum](https://github.com/charmbracelet/gum) (auto-installed if missing)
- [s3cmd](https://s3tools.org/s3cmd) (auto-installed if missing, only needed for S3)
- [rsync](https://rsync.samba.org/) (auto-installed if missing, only needed for `dir` restore)

## Setup

### S3 configuration

Configure the S3 backend interactively:

```bash
parbackup config set
```

This saves credentials to `~/.config/par/parbackup.conf`. View current config:

```bash
parbackup config
```

### Parbackupfile

Place an `Parbackupfile` in your deployment directory:

```bash
BACKUP_NAME="my_project"

SERVICES="app_db,app_mongo,app_uploads,app_static"

APP_DB_TYPE="postgres"
APP_DB_CONTAINER="my-project-postgres-1"
APP_DB_USER="postgres"
APP_DB_PASSWORD="secret"
APP_DB_DB="mydb"

APP_MONGO_TYPE="mongo"
APP_MONGO_CONTAINER="my-project-mongo-1"
APP_MONGO_USER="root"
APP_MONGO_PASSWORD="secret"
APP_MONGO_DB="mydb"

APP_UPLOADS_TYPE="volume"
APP_UPLOADS_CONTAINER="my-project-app-1"
APP_UPLOADS_PATH="/app/public/uploads"

APP_STATIC_TYPE="dir"
APP_STATIC_PATH="/opt/my-project/static"
```

| Variable          | Description                                             |
| ----------------- | ------------------------------------------------------- |
| `BACKUP_NAME`     | Name of this deployment (used in backup directory name) |
| `SERVICES`        | Comma-separated list of service names                   |
| `<SVC>_TYPE`      | Service type: `postgres`, `mongo`, `volume`, or `dir`   |
| `<SVC>_CONTAINER` | Docker container name (`postgres`, `mongo`, `volume`)   |
| `<SVC>_USER`      | Database user (`postgres`, `mongo`)                     |
| `<SVC>_PASSWORD`  | Database password (`postgres`, `mongo`)                 |
| `<SVC>_DB`        | Database name (`postgres`, `mongo`)                     |
| `<SVC>_PATH`      | Path to back up (`volume`, `dir`)                       |

`<SVC>` is the uppercase version of the service name defined in `SERVICES`.

### Service types

- **`postgres`** — Online `pg_dump`/`pg_restore` of a Postgres database running in a Docker container.
- **`mongo`** — Online `mongodump`/`mongorestore` of a MongoDB database running in a Docker container.
- **`volume`** — Copies files from a Docker container path via `docker cp`. Useful for named volumes (e.g. upload directories). Restore clears the target path first.
- **`dir`** — Copies a local directory via `cp -a`. Restore uses `rsync --delete` for a clean sync. Useful for bind-mounted host directories or any local path.

## Usage

```bash
# Create backup, package as tar.gz, upload to S3
parbackup create

# Create backup locally only (no S3 config needed)
parbackup create --local

# List backups on S3
parbackup ls
parbackup ls my_project/

# List backups as a directory tree
parbackup ls --tree

# List backups with S3 timestamps (epoch\tkey per line)
parbackup ls --timestamps

# Delete backups older than retention period (configured via RETENTION_DAYS)
parbackup cleanup

# Download a backup from S3 to /tmp/
parbackup download my_project/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Interactively pick a backup from S3 to download (fuzzy search)
parbackup download --pick

# Interactively pick a backup from S3 to restore (fuzzy search)
parbackup restore --pick

# Restore from S3 (prompts for confirmation)
parbackup restore my_project/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Restore from local tar.gz or directory
parbackup restore --local /tmp/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Skip confirmation prompt
parbackup restore --force --local /tmp/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Schedule backups via cron
parbackup cron -f /path/to/Parbackupfile
parbackup cron -f /path/to/Parbackupfile --schedule "0 3 * * *"
parbackup cron show
parbackup cron remove -f /path/to/Parbackupfile

# Update script
parbackup updateself
```

Backups are written to `/tmp/parbackup-<BACKUP_NAME>-<timestamp>.tar.gz`. The archive contains one subdirectory per service, the `Parbackupfile`, and an `parbackup.log` with timestamped log output from the backup run. On S3, backups are stored under `<BACKUP_NAME>/` prefix.

### Logging

Each `parbackup create` run produces two log files:

- **Backup log** (`parbackup.log`) — included inside the `.tar.gz` archive. Contains timestamped entries for each backup step up to packaging. Useful for auditing what happened during a specific backup.
- **Run log** (`/tmp/parbackup-runs/run-XXXXXXXXXX.log`) — an ephemeral log that captures the entire run including S3 upload and post-packaging steps. The first two entries are always the full command invocation and the current working directory. Automatically deleted on success; kept on failure for debugging. If alert SMTP is configured, the run log content is included in the error notification email.

### Download

Use `download` to fetch a backup archive from S3 without restoring it:

```bash
# Download by S3 key
parbackup download my_project/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Interactively pick a backup to download (fuzzy search)
parbackup download --pick

# Overwrite an existing local file without prompting
parbackup download --force my_project/parbackup-my_project-2026-02-27_14-30-22.tar.gz
```

The archive is saved to `/tmp/`. `restore` uses `download` internally when fetching from S3.

### Restore

By default, `restore` downloads from S3 and restores immediately. Use `--local` to restore from a local `.tar.gz` archive or unpacked directory:

```bash
# Restore from S3 (prompts for confirmation)
parbackup restore my_project/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Interactively pick a backup to restore
parbackup restore --pick

# Restore from a local archive
parbackup restore --local /tmp/parbackup-my_project-2026-02-27_14-30-22.tar.gz

# Skip confirmation prompt
parbackup restore --force --local /tmp/parbackup-my_project-2026-02-27_14-30-22.tar.gz
```

### Retention

Set `RETENTION_DAYS` via `parbackup config set` to automatically delete old backups. When configured, old backups are cleaned up after each successful `create`. You can also run `parbackup cleanup` manually. Set to `0` to disable.

### Cron

Schedule backups with the built-in cron manager:

```bash
# Add or update a cron entry (interactive frequency picker)
parbackup cron -f /path/to/Parbackupfile

# Add or update with a specific schedule (non-interactive)
parbackup cron -f /path/to/Parbackupfile --schedule "0 3 * * *"

# Show all parbackup cron entries
parbackup cron show

# Remove the cron entry for a specific Parbackupfile
parbackup cron remove -f /path/to/Parbackupfile
```

Each cron entry is tagged with a `# parbackup:<BACKUP_NAME>` marker so entries can be identified, updated, and removed by backup name. The `-f` path is resolved to an absolute path via `realpath`.

### Error notifications

If a backup fails (during creation or S3 upload), an error notification email is sent via SMTP. The email includes the exit code, failing line number, and the full run log content (if available). Configure it interactively:

```bash
parbackup config set alert
```

This stores the following settings in `~/.config/par/parbackup.conf`:

| Variable              | Description                                      |
| --------------------- | ------------------------------------------------ |
| `ALERT_SMTP_HOST`     | SMTP server hostname                             |
| `ALERT_SMTP_PORT`     | SMTP server port (default: `587`)                |
| `ALERT_SMTP_USER`     | SMTP username (leave empty for no authentication)|
| `ALERT_SMTP_PASSWORD` | SMTP password                                    |
| `ALERT_SMTP_FROM`     | Sender address for notification emails           |
| `ALERT_RECIPIENTS`    | Comma-separated list of recipient addresses      |

Emails are sent using `curl` (no additional dependencies). If alert SMTP is not configured, error notifications are silently skipped.

## Development

A test deployment is included in `./test/` with Postgres, MongoDB, a Docker volume container, and a local directory, plus seed data.

### Running the test stack manually

```bash
cd test/
docker compose up -d
../parbackup create --local
../parbackup restore --local --force /tmp/parbackup-test_deployment-<timestamp>.tar.gz
docker compose down -v
```

### Running the automated tests

Requires [bats-core](https://github.com/bats-core/bats-core).

```bash
bats test/test.bats
```

The test suite starts the stack, creates a backup, verifies archive contents, modifies data in all services, restores from the tar.gz, and verifies the original data is back. Cleans up automatically.
